# 基于阿里云的公网远程访问与控制 DeepSeek Harness

**Reach the DeepSeek Harness (dsh) web GUI from anywhere through a cheap cloud relay**

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![SSH tunnel](https://img.shields.io/badge/SSH-reverse%20tunnel-4D4D4D?logo=openssh&logoColor=white)](#)
[![HTTPS gateway](https://img.shields.io/badge/HTTPS-auth%20gateway-3B82F6?logo=letsencrypt&logoColor=white)](#)
[![Aliyun](https://img.shields.io/badge/Aliyun-ECS-FF6A00?logo=alibabacloud&logoColor=white)](#)
[![Platform](https://img.shields.io/badge/Platform-Windows%20%2B%20Linux-0078D4)](#)

**电脑在任何网络下**（家庭宽带、5G 热点、外地 WiFi、校园网、运营商 CGNAT 大内网），
手机都能通过一个固定的公网地址访问这台电脑上的 dsh GUI。

> **本项目提供三种由弱到强的接入方式**，可以按需选择或叠加：
>
> | 方式 | 手机要求 | 加密 | 认证 | 公网端口 |
> |---|---|---|---|---|
> | ① frp 反向隧道（起步方案） | 浏览器 | 隧道段加密 | dsh token | 7000 + 18080 |
> | ② **SSH 反向隧道**（推荐） | SSH 客户端 | **SSH** | 密钥 | **仅 22** |
> | ③ **HTTPS 认证网关** | **仅浏览器** | **TLS** | **密码** | 22 + 18443 |
>
> ③ 是**原生鸿蒙（无 SSH 客户端）唯一可行**的方案；
> 配合 `dsh-token-broadcast` 插件自动上报 token，用户只需输一次密码。
> 演进过程与实测结论见 [`docs/UPDATES-2026-09-23.md`](docs/UPDATES-2026-09-23.md)。

---

## 零、三种方式怎么选

- **只想最快跑通** → 用 ①（`docs/DEPLOY.md` 的 frp 主线）
- **追求最小暴露面 + 最安全** → 用 ②（`src/tunnel/`，公网只剩 22 端口）
- **手机是原生鸿蒙 / 不想装任何客户端** → 用 ③（`src/gateway/`）

②③ 都已在真实环境验证通过：②的公网端口收敛到仅 SSH；③的浏览器流程
（登录 → 直接进 GUI → WebSocket 101）见 `tests/`。

---

## 一、为什么是中继，而不是端口映射

| 方案 | 前提 | 适用性 |
|---|---|---|
| 端口映射 / DDNS | 电脑要有**公网 IP**，且能在路由器上开端口 | ❌ 电脑在随机网络间切换时经常不成立，甚至处在运营商 CGNAT 之后 |
| **反向隧道中继（本项目）** | 只需**服务器**有公网 IP | ✅ 电脑**主动连出**到服务器，对 CGNAT 与入站封锁**免疫** |

关键点：连接方向是「电脑 → 服务器」，所以**电脑侧不需要任何入站端口**。

### 方式①：frp（起步方案）

```
手机 ──► <服务器公网IP>:18080 ──► [frps] ──► 反向隧道 ──► 电脑 frpc
              (公网入口)          (云服务器)   (电脑主动连出)     │
                                                                 ▼
                                          127.0.0.1:18080 (dsh-entry-proxy)
                                                                 │
                                                                 ▼
                                                      127.0.0.1:3080 (dsh web)
```

`dsh web` 本体始终只监听环回；公网只暴露 frps 的**一个**端口。

---

## 二、⚠️ 云服务器免费额度的真实机制（选型最易踩坑）

以阿里云个人试用为例，它**不是"送一台机器 N 个月"**，而是：

| 机制 | 数值 |
|---|---|
| 总抵扣额度 | **300 元**（个人实名认证） |
| 每小时抵扣上限 | **0.833 元/小时** |
| 权益有效期 | **最长 3 个月** |
| 理论最长运行 | **约 1181 小时 ≈ 49 天** |

**核心结论**：

1. **必须选单价 ≤ 0.833 元/小时的规格**。若选了例如 1.2 元/小时的规格，
   超出的 0.367 元/小时**要你自己付钱**，还会更快烧完新用户权益。
2. **规格越小跑得越久**；1核1G 不建议，推荐 **经济型 e 实例 2核2G 或 2核4G**。
3. 免费实例**不支持 ICP 备案**，所以用 **7000 / 18080** 非标端口——既避开备案，也不冲突。
4. 到期或额度耗尽会**自动释放实例，数据只保留 72 小时**：服务器上只放**可重建**的东西。
5. 同一实名主体**只能领一次**；买过/试用过 ECS 的账号可能已失去资格。

**务必设置预算告警**：控制台 → 费用与成本 → 预算管理 → 阈值 1 元。

---

## 三、目录结构

```
.
├── README.md
├── LICENSE
├── package.json
├── docs/
│   ├── DEPLOY.md                   从零部署：8 步 + 排错表
│   ├── ARCHITECTURE.md             链路细节、七个设计决策、分层验证法
│   ├── SECURITY.md                 三道防线、凭据清单、SSH 加固、自查清单
│   ├── MIGRATION.md                换服务器四步 / 换电脑三步
│   └── UPDATES-2026-09-23.md       本次演进汇总（SSH 隧道 + HTTPS 网关 + 实测结论）
├── src/
│   ├── server/
│   │   ├── relay-server-setup.sh   服务器端一键部署 frps（自包含）
│   │   └── aliyun-paste-command.sh 适合直接粘贴进网页控制台的版本
│   ├── client/
│   │   ├── frpc.toml.template      电脑端配置模板（两处占位符）
│   │   └── ssh-key-setup.ps1       SSH 密钥登录 + 加固（纯 ASCII）
│   ├── tunnel/                     ★ 方式②：SSH 反向隧道（取代 frp）
│   │   ├── Start-SshTunnel.ps1     隧道客户端 + 掉线自愈（纯 ASCII）
│   │   ├── Switch-ToSshTunnel.ps1  从 frp 一次性切换过来
│   │   └── relay-ssh-hardening.sh  服务器加固 + 退役 frps
│   └── gateway/                    ★ 方式③：HTTPS 认证网关
│       ├── dsh-auth-gateway.mjs          网关本体（TLS + 密码 + 会话 + WS 隧道）
│       ├── install-auth-gateway.sh       一键部署 + 生成注册密钥 + systemd
│       ├── issue-ca-and-server-cert.sh   建 10 年 CA 并签发服务器证书
│       └── install-node-official.sh      apt 只有 Node 12，改用官方二进制
└── tests/
    ├── browser-flow-test.mjs       严格模拟浏览器 cookie 流转
    └── test-skip-token.mjs         验证"只输密码即可进入 GUI"
```

### 方式②：SSH 反向隧道（取代 frp）

```
手机 ──ssh -L 18080:127.0.0.1:18080──► 服务器:22 ──隧道──► 电脑:18080 ──► dsh:3080
```

- 电脑执行 `ssh -N -R 18080:127.0.0.1:18080 dsh-aliyun`
- 服务器侧只得到 **127.0.0.1:18080**（不指定 bind 地址时 sshd 默认绑环回，且 `GatewayPorts no`）
- **公网只剩 22 一个端口**；7000 与 18080 都可以从安全组删掉
- 掉线自愈：`Start-SshTunnel.ps1` 内置监督循环（PC 换网必掉线）

### 方式③：HTTPS 认证网关（手机只需浏览器）

```
手机 ──https(18443)──► 服务器网关(密码认证 + TLS) ──► 127.0.0.1:18080 ──► dsh:3080
                                                        （方式②建立的隧道）
```

网关的关键设计（都在 `docs/UPDATES-2026-09-23.md` 里详述）：

1. **网关持有 dsh 会话，浏览器只持有网关会话**。
   dsh 的会话 cookie 按 authority 命名，网关改写 `Host` 后若原样透传 cookie，
   浏览器会存在错误域名下、后续请求带不回去（表现为 `authentication required`）。
2. 转发时**去掉 `Origin`**、把 `Host` 改写为 `127.0.0.1:18080` → 穿过 dsh 信任围栏。
3. **隧道 WebSocket 升级**，否则会话列表为空、一直"自动重连中"。
4. **token 自动上报**：电脑上的 `dsh-token-broadcast` 插件用注册密钥把 token
   上报到 `/__gw_register`，于是浏览器**只输密码**即可进入，无需粘贴 token。

---

## 四、端口与要放行的地方

| 端口 | 用途 | 谁监听 |
|---|---|---|
| **7000** | frpc 连入 frps | 云服务器 |
| **18080** | 手机访问的公网入口 | 云服务器 frps → 隧道 → 电脑 `127.0.0.1:18080` |

要放行的只有**两处**（电脑侧不需要，因为是主动连出）：

1. **云控制台安全组**（网页操作，脚本无法代劳）：入方向 TCP 7000 与 18080
2. **服务器自带防火墙**（ufw / firewalld）：部署脚本会自动放行

---

## 五、快速开始

整体八步，详见 **[`docs/DEPLOY.md`](docs/DEPLOY.md)**：

1. 注册 + 个人实名认证 → 领免费试用 ECS（2核2G，**确认单价 ≤0.833 元/小时**）
2. 安全组放行 7000、18080
3. 控制台「远程连接」里粘贴 `src/server/aliyun-paste-command.sh` → **记下打印的 token**
4. 下载 frpc.exe，把 `src/client/frpc.toml.template` 复制为 `frpc.toml` 并填两个占位符
5. 手工跑一次 frpc，看到 `start proxy success`
6. 把公网 IP 加进 `cordis.patch.yml` 的 `trustedHosts`（**两处**），重启 dsh
7. 手机打开 `http://<公网IP>:18080/?token=<token>`
8. 可选：用 `src/client/ssh-key-setup.ps1 -Harden` 关闭 SSH 密码登录

> **依赖说明**：本项目需要电脑侧有一个监听 `127.0.0.1:18080` 的入口代理。
> 它由姊妹项目 [`dsh-lan-remote-access`](https://github.com/MaybeMeibeMaybi/dsh-lan-remote-access)
> 的 `dsh-entry-proxy.mjs` 提供（多配一条 `bindIp: 127.0.0.1` / `port: 18080` 的条目即可）。
> 两个项目建议一起部署。

---

## 六、最易漏的一步：信任围栏

dsh 的 `/api` 会比较 `Host` 与 `Origin`，并要求 authority 属于"环回或已声明可信"。
**公网 IP 不写进去，手机访问一律 403**，且任何代理都无法靠改写 Host 绕过。

```yaml
- id: web-runtime
  config:
    trustedHosts:
      - <电脑LAN地址>
      - <服务器公网IP>          # 必须加
- id: connection
  config:
    trustedHosts:
      - <电脑LAN地址>
      - <服务器公网IP>          # 必须加（两处缺一不可）
```

---

## 七、安全（详见 [`docs/SECURITY.md`](docs/SECURITY.md)）

三道防线，缺一不可：

| 防线 | 保护什么 |
|---|---|
| ① 安全组只放行 7000 / 18080 | 减少暴露面 |
| ② frps `auth.token` | 防止陌生人往你的隧道注册代理 |
| ③ dsh 会话 token + 信任围栏 | **真正的访问控制** |

- frp token 由部署脚本随机生成，存于服务器 `/opt/frp/frp-token`（权限 600）。
- frps 的 `allowPorts` 只放开 18080 一个 remotePort，防止隧道被滥用。
- **入口代理不是鉴权层**：它只负责转发，真正拦人的是第 ③ 道。
- 建议 SSH 改密钥登录并关闭密码（脚本 `-Harden`，且会**立即复验**，不会把你锁在门外）。

## 八、迁移

- **换服务器**：新机器重跑部署脚本 → 改 `frpc.toml` 两行 → 改 `trustedHosts` → 重启 dsh。**四步，十分钟。**
- **换电脑**：部署姊妹项目 → 拷 `frpc.toml` → 配 `trustedHosts`。

详见 **[`docs/MIGRATION.md`](docs/MIGRATION.md)**。

## 许可证

MIT，见 [`LICENSE`](LICENSE)。
