# 事故复盘：网关"没收到 token"导致远程端登录不了（2026-09-27）

> 真实事故记录。**所有站点地址、授权码、密钥路径均已去标识化**。
> 目的是让这条链路的失败模式可查、可复现、可自证。

---

## 一、现象

用户报告：dsh 卡死 → 手动停止并重启 → **远程端网页登录显示"网关尚未收到本次启动的 token"**，
手工把负一屏卡片里的 token 粘进去，仍然**无效**。

同一时间局域网入口（`http://<LAN-IP>:3081/`）虽然能打开页面，但一直"自动重连中"、
看不到任何会话记录。

---

## 二、链路结构（先明确有几段）

```
手机 ──https:18443──► [公网服务器] dsh-auth-gateway（密码 + 会话 cookie）
                          │  内部用 dsh token 换 dsh 会话 cookie
                          ▼
                      ssh 反向隧道（服务器 127.0.0.1:18080）
                          ▼
                  电脑 dsh-entry-proxy（127.0.0.1:18080）
                          ▼
                      dsh web（127.0.0.1:3080）

手机 ──http:3081──► 电脑 dsh-entry-proxy（绑定局域网地址）──► dsh web:3080
```

两段的关键差异：**局域网入口只需要 token 在 URL 里**；
**网关需要先把 token 注册进去**，才能替浏览器换取 dsh 会话 cookie。

---

## 三、根因（两条独立的失败，被同一个现象掩盖）

### 3.1 网关**只在内存里存 token**，注册漏一次就全灭

网关的 `tokenState` 是进程内存变量。dsh 每次重启都会换 token，因此每次都要重新注册。
注册由电脑上的 `token-broadcast` 插件在启动时调用 `POST /__gw_register` 完成。

**问题**：那次注册是**只试一次、失败即静默放弃**。而 dsh 刚重启时，
网关与 SSH 隧道恰好都在重连 —— 这一次注册很容易撞在窗口期。
漏掉之后：

- 网关侧：`tokenState.dshCookie` 为空 → 密码登录后返回
  "网关尚未收到本次启动的 token"（手工粘贴同样失败）；
- 用户侧：卡片里的 token 是真的，但网关根本没拿它去换 cookie，
  所以**输什么都无效** —— 这个现象最容易被误判成"token 错了"。

实测探测（当时）：

```
GET  /__gw_health   -> 200 ... (backend ready; token NOT registered)
POST /__gw_register -> 200 {"ok":true,"sessions":1}     # 手工补一次就好了
```

### 3.2 局域网入口的"自动重连中"是 **WebSocket**，不是会话记录丢了

`/api/remote.mux` 是 UI 的实时通道，必须做 **WebSocket 升级**。
代理进程是**长连接反向代理**：升级后的 socket 会一直挂在**当时那个 dsh 实例**上。
dsh 重启后旧 socket 全失效，而**代理不重启就仍指向旧实例**，
于是页面能渲染、但 WS 一直失败 → "自动重连中"、会话列表空。

实测：对旧代理做升级请求得到 `HTTP/1.1 502 Bad Gateway`；
重启代理后同一条请求得到 **101 Switching Protocols**。

---

## 四、修复

### 4.1 注册改成"可重试 + 可查"（`token-broadcast` 插件）

- 失败**自动重试 3 次**（间隔 5 秒，`registerAttempts` / `registerRetryMs` 可配）；
- 结果写入 `<DSH_HOME>/lan/token-broadcast/register-status.json`
  （成功/失败、HTTP 码、网关响应、token 尾部 8 位 —— **不写完整 token**）；
- 最终失败时日志明确写出"远程端会显示网关尚未收到本次启动的 token"，
  并给出复查入口 —— 不再静默。

### 4.2 新增体检工具 `tools/verify-gateway.mjs`

一条命令把"远程为什么进不去"拆成可判定的四段：

```
node tools/verify-gateway.mjs              # 只体检，不改动任何东西
node tools/verify-gateway.mjs --register    # 体检 + token 缺失时补注册
```

检查：dsh 是否在跑且 `web-state.json` 属于当前进程 → 网关可达性/后端 ready/是否已注册
→ 局域网入口带 token 是否 303 → `register-status.json` 内容。

配置全部走环境变量（**源码里不含任何真实地址**）：
`DSH_GW_HOST` / `DSH_GW_PORT` / `DSH_GW_KEY_FILE` / `DSH_ENTRY_PORT`。

### 4.3 入口代理：换网自动跟随 + 排除虚拟网卡

`src/tunnel/dsh-entry-proxy.mjs`（局域网与中继共用一份）现在：

- **自动探测并跟随**局域网地址：不带 `--bind-ip` 时监听网卡事件 + 定时兜底复查，
  地址变化就 re-listen（早期版本会因 `EADDRINUSE` 直接退出）；
- **排除虚拟/隧道网卡**（Tailscale、Hyper-V、VirtualBox、WSL、Docker…）
  与 APIPA `169.254`、Tailscale CGNAT `100.64/10`，并按 RFC1918 优先级挑地址。
  否则「取第一个 IPv4」可能绑到手机根本路由不到的地址上，
  表现与"绑在过期地址"完全一样（页面能开、会话为空、一直重连）。

---

## 五、运维要点（下次出问题按这个顺序查）

1. **先跑体检工具**，它会直接指出是哪一段断了。
2. **"网关尚未收到 token" ≠ token 错**：多半是注册没到，补注册即可，别急着重启 dsh。
3. **"自动重连中" = WebSocket 没建起来**：先看入口代理是否还指向**当前** dsh 实例
   （dsh 重启后代理需要一起重启）。
4. **隧道与网关都在服务器侧**：`ssh-tunnel.log` 里的重连记录说明隧道断过，
   断了远程同样进不来 —— 与 token 无关。
5. 排查完**先记录下来**：本次事故的两个坑（注册静默失败、代理长连接钉死旧实例）
   都是"看起来像 A、其实是 B"的类型。
