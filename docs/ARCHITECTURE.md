# 架构与设计决策：为什么是这样

本文件记录链路细节与每个关键设计选择的**原因**——多数是踩坑后定下来的，
迁移或排错时先读这里能省很多时间。

---

## 1. 数据流（一次手机访问的完整路径）

```
手机浏览器
   │  GET http://<公网IP>:18080/?token=<dsh token>
   │  Host: <公网IP>:18080
   ▼
云服务器安全组（放行 18080）
   ▼
frps（/opt/frp/frps.toml，bindPort 7000，allowPorts 仅 18080）
   │  收到该端口的连接 → 查路由表 → 通过已建立的隧道转发
   ▼
frpc（电脑侧，主动连出到 7000，注册了 proxy "dsh-web": remotePort 18080 → localPort 18080）
   │  把字节流交给本机 127.0.0.1:18080
   ▼
dsh-entry-proxy.mjs（绑 127.0.0.1:18080）
   │  · 普通请求：原样转发（Host / Origin / Cookie 不改写）
   │  · Upgrade 请求：原始 socket 双向隧道（/api/remote.mux 实时连接）
   ▼
dsh web（127.0.0.1:3080）
   │  浏览器信任围栏：Host/Origin 必须是环回或 trustedHosts 之一 → 再验会话
   ▼
返回页面 / 建立 WebSocket 实时通道
```

---

## 2. 七个关键设计决策

### ① 用反向隧道，而不是端口映射

电脑在随机网络间切换，常常没有公网 IP，甚至处在运营商 CGNAT 之后。
反向隧道让**电脑主动连出**到有公网 IP 的服务器，因此对入站封锁完全免疫，
而且电脑侧**不需要开任何入站端口**。

### ② frp 的 remotePort / localPort 是"端口到端口"映射

这是最容易误解的一点：服务端把流量交到电脑的 `localPort`，
所以**电脑上必须有进程监听那个端口**。

- 局域网入口：代理绑 LAN 地址 **3081**
- 中继入口：代理绑 **127.0.0.1:18080**（与 `remotePort` 同号，便于排查）

绑 127.0.0.1 而非 0.0.0.0 是刻意的：这样这个端口**只允许本机的 frpc 送入**，
永远不会被局域网或公网直接访问到。

### ③ 代理必须原样透传 Host / Origin

dsh 的 `/api` 信任围栏会比较 `Host` 与 `Origin`，并要求 authority 属于
"环回或已声明可信"。它的设计目的就是防止 DNS rebinding，所以
**任何代理都无法靠改写 Host 绕过**。

实测证据：用 `Host: <LAN>:3081` 直连环回端口得到 **403**；
把该 authority 加进 `trustedHosts` 后放行。

推论：**换 IP（换路由器 / 换服务器）必须同步改 `trustedHosts`**，
而且 `web-runtime` 与 `connection` **两处都要改**（前者持有值，后者是围栏）。

### ④ 代理必须隧道 WebSocket

dsh 的实时数据面是 **`/api/remote.mux`** 这个 WebSocket。
只转发普通 HTTP 的代理会导致：页面能渲染、但**会话列表为空**、
左下角一直显示**"自动重连中"**。

所以 `dsh-entry-proxy.mjs` 实现了 `server.on('upgrade')`：
把客户端 socket 与上游 socket 双向 `pipe`，并在任一端关闭/出错时一起销毁。

### ⑤ 代理由 dsh 插件启动，而不是独立计划任务

独立启动器/计划任务会和 dsh 抢端口。放进 dsh 进程内的插件后：

- dsh 先起，代理后起，顺序天然正确
- 插件启动前**先探测健康端点**，已在服务就复用，不产生重复实例
- 子进程 `detached + unref`，可活过本次 dsh 运行；下次启动直接复用
- 代理自身也捕获 `EADDRINUSE` 后**安静退出**，作为第二道保险

**探测地址必须与绑定地址一致**：对只绑 LAN 地址的代理探 `127.0.0.1` 永远是
`ECONNREFUSED`，会导致每次启动都重复拉起一个必然失败的实例（这个坑踩过）。

### ⑥ 用启动文件夹做开机自启，而不是计划任务

`schtasks` / `Register-ScheduledTask` 在非管理员会话下会被拒绝
（`Access is denied`）。启动文件夹
（`shell:startup`）免提权即可生效，配合桌面启动器里的幂等补拉，形成双保险。

### ⑦ 启动器必须"先探测端口再决定"

否则每次双击都会尝试启动第二个实例，撞上 `EADDRINUSE 3080`。
**这个报错通常不代表 dsh 崩了**，而是"旧实例还健康地占着端口"。
启动器现在的行为：3080 在监听 → 只打开界面；否则才启动，并等待端口就绪后打开带 token 的地址。

---

## 3. 凭据与状态文件

| 文件 | 内容 | 说明 |
|---|---|---|
| `/opt/frp/frp-token`（服务器） | frp token | 权限 600，脚本随机生成 |
| `relay\frpc.toml`（电脑） | serverAddr + frp token | 纯文本；不要外传 |
| `~/.dsh/lan/web-state.json` | dsh 会话 token | 启动器写入；**每次重启 dsh 都会变** |
| `~/.dsh/profiles/web/cordis.patch.yml` | trustedHosts、代理配置、负一屏 authCode | 单个文件承载全部 dsh 侧配置 |

dsh 的会话 token **只在启动时打印一次到 stdout，不落盘**——所以启动器的职责之一
就是从自己捕获的日志里把它取回来（并且**校验有效**：有效 token 会得到 303）。

---

## 4. 失效模式与对应设计

| 失效模式 | 设计上的应对 |
|---|---|
| 电脑换网络（IP 变化） | frpc `loginFailExit = false` + 自动重连；公网入口 IP 不变，手机地址无需改 |
| frpc 被杀/崩溃 | 启动文件夹自启 + 桌面启动器幂等补拉 |
| dsh 重启（token 变化） | 启动器自动捕获并写入 `web-state.json` |
| 代理端口被占 | 代理安静退出 + 插件先探测复用 |
| 隧道端口未放行 | `__proxy_health` 端点可分别验证"本机段"与"公网段"，快速定位是哪一跳 |
| 服务器到期被释放 | 服务器上无可重建之外的数据；迁移见 `MIGRATION.md`，四步十分钟 |

---

## 5. 分层验证法（排错时按顺序做，能立刻定位到哪一跳坏了）

```powershell
# 第 1 跳：dsh 本体
(Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:3080/' -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
# 401 = 服务正常（需要 token）

# 第 2 跳：本机中继入口代理
(Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:18080/__proxy_health').Content
# 期望 entry-proxy ok

# 第 3 跳：公网 → frps → 隧道 → 本机代理
(Invoke-WebRequest -UseBasicParsing 'http://<公网IP>:18080/__proxy_health').Content
# 期望 entry-proxy ok；若不通过，问题在 frps/frpc/安全组

# 第 4 跳：会话建立（token 是否有效）
$tok = (Get-Content "$env:USERPROFILE\.dsh\lan\web-state.json" -Raw | ConvertFrom-Json).token
(Invoke-WebRequest -UseBasicParsing "http://<公网IP>:18080/?token=$tok" -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
# 期望 303；401 = token 失效（重启 dsh 后需重取）
```

403 出现在第 4 跳 → `trustedHosts` 没写对；超时出现在第 3 跳 → 安全组或 frpc；
第 2 跳不通 → 代理没起（看 `entry-startup` 插件日志）。
