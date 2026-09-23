# 从零部署：阿里云公网中继

前置：已完成 **lan-remote-access** 的部署（需要它的 `dsh-entry-proxy.mjs` 与
`dsh-entry-startup` 插件）。全程约 30 分钟，其中大半是等云主机创建。

---

## 第 1 步：注册与领取免费试用

1. https://www.aliyun.com 注册 → **个人实名认证**（刷脸，几分钟）。
   - 同一实名主体**只能领一次**；买过/试用过 ECS 的账号可能已失资格。
2. 打开 https://free.aliyun.com/ → ECS 云服务器 → 立即试用。
3. 选型（**省钱关键**）：

| 项目 | 建议 |
|---|---|
| 规格 | 经济型 e，**2核2G**（或 2核4G）；1核1G 太弱不建议 |
| 镜像 | **Ubuntu 22.04 / 24.04 64 位**（脚本按 Ubuntu/Debian 编写） |
| 系统盘 | 40G ESSD Entry（默认） |
| 带宽 | 按使用流量计费（内地每月 20GB 免费流量，够用） |
| 地域 | 离你最近的内地节点（**创建后不能改**） |
| 登录 | 密钥对优先，其次强密码 |

4. **在确认页核对预估单价 ≤ 0.833 元/小时**，否则超出部分自费。
5. 创建后记下**公网 IP**。
6. 立刻设置预算告警：费用与成本 → 预算管理 → 阈值 **1 元**。

---

## 第 2 步：安全组放行（网页操作）

实例 → 安全组 → 配置规则 → **入方向** → 手动添加：

| 协议 | 端口范围 | 授权对象 |
|---|---|---|
| TCP | **7000/7000** | 0.0.0.0/0 |
| TCP | **18080/18080** | 0.0.0.0/0 |

> 想更严格可把 7000 限制为家庭出口 IP，但电脑会在随机网络间切换，故默认放开，
> 安全性由 frps 的 token 承担。

---

## 第 3 步：登录服务器

**方式 A（推荐，免装工具）**：控制台实例列表 → 「远程连接」→ root 登录。
**方式 B**：本地 `ssh root@<公网IP>`（密钥登录见第 6 步）。

---

## 第 4 步：部署 frps

把 `src/server/aliyun-paste-command.sh` 的**全部内容**复制粘贴进控制台终端：

```bash
# 想先自查语法（可选）
bash -n aliyun-paste-command.sh
```

脚本会自动：

- 识别架构（x86_64 / aarch64）→ 下载 frp（GitHub 失败自动走镜像）
- 生成随机 token → `/opt/frp/frp-token`（权限 600）
- 写 `/opt/frp/frps.toml`（只允许 remotePort = 18080，防滥用）
- 注册 systemd 服务 `frps` 并**开机自启**
- 放行 ufw / firewalld 的 7000、18080
- **打印三行：公网 IP / 连接端口 / token**

> ⚠️ **把 token 记下来**，第 5 步要用。它是这条隧道的钥匙，别发群聊、别提交仓库。
> 服务器上随时可查：`cat /opt/frp/frp-token`

**验证**：

```bash
systemctl is-active frps          # active
ss -lntp | grep -E '7000|18080'   # 两个端口都在监听
```

---

## 第 5 步：电脑端配置 frpc

1. 下载 frp Windows 版：https://github.com/fatedier/frp/releases
   → `frp_<版本>_windows_amd64.zip`（国内慢可用镜像站）
2. 解压出 `frpc.exe`，放到 `E:\DSH\dsh-hiboard\relay\`
3. 把 `src/client/frpc.toml.template` 复制为该目录下的 `frpc.toml`，
   替换两个占位符：

```toml
serverAddr = "<RELAY_HOST>"     # 第 4 步打印的公网 IP
auth.token = "<FRP_TOKEN>"      # 第 4 步打印的 token
```

4. 手工跑一次验证：

```powershell
cd 'E:\DSH\dsh-hiboard\relay'
.\frpc.exe -c .\frpc.toml
```

期望看到：

```
login to server success
[dsh-web] start proxy success
```

5. **注册开机自启**（不需要管理员权限）：把下面内容存为
   `shell:startup\dsh-relay-frpc.cmd`（**必须纯 ASCII**）：

```bat
@echo off
set RELAY=E:\DSH\dsh-hiboard\relay
if not exist "%RELAY%\frpc.exe" exit /b 0
"%RELAY%\frpc.exe" -c "%RELAY%\frpc.toml"
```

> 用 `schtasks` 注册计划任务会因权限被拒（`Access is denied`），启动文件夹是免提权的替代方案。
> 桌面启动器也会在每次运行时检查并补拉 frpc（幂等），两者互为保险。

---

## 第 6 步：SSH 改密钥登录（可选但建议）

1. 把公钥装进服务器（控制台粘贴，`<PUBKEY>` 换成你的公钥内容）：

```bash
mkdir -p /root/.ssh && chmod 700 /root/.ssh && echo '<PUBKEY>' >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys && echo KEY_INSTALLED
```

2. 电脑端验证（脚本会写 `~/.ssh/config` 别名 `dsh-relay`）：

```powershell
powershell -File .\ssh-key-setup.ps1 -SshHost <公网IP> -KeyPath "$env:USERPROFILE\.ssh\dsh_relay"
```

3. 稳定后加固（关闭密码登录，保留密钥；**控制台 VNC 仍是救急通道**）：

```powershell
powershell -File .\ssh-key-setup.ps1 -SshHost <公网IP> -KeyPath "$env:USERPROFILE\.ssh\dsh_relay" -Harden
```

> 脚本会在加固后**立即复验密钥登录**，失败会打印 VNC 里可执行的回滚命令，
> 不会把你锁在门外。

---

## 第 7 步：让 dsh 接受公网来源（**最易漏，漏了就是 403**）

编辑 `~/.dsh/profiles/web/cordis.patch.yml`，在 **`web-runtime` 与 `connection` 两处**
`trustedHosts` 里都加上服务器公网 IP：

```yaml
- id: web-runtime
  config:
    trustedHosts:
      - <电脑的LAN地址>
      - <公网IP>            # ← 新增
- id: connection
  config:
    trustedHosts:
      - <电脑的LAN地址>
      - <公网IP>            # ← 新增
```

并确认 `entry-startup` 的 `proxies` 里有中继那条：

```yaml
- insert:
    - id: entry-startup
      name: dsh-entry-startup
      config:
        proxies:
          - label: lan-proxy
            scriptPath: 'E:\DSH\dsh-entry-proxy.mjs'
            port: 3081
          - label: relay-proxy
            scriptPath: 'E:\DSH\dsh-entry-proxy.mjs'
            port: 18080
            bindIp: '127.0.0.1'      # ← 只允许本机 frpc 送入
```

**重启 dsh 前先预检**（只读，不起服务）：

```powershell
dsh --profile web --dump-config | Select-Object -First 5
# 正常：上万字符输出；异常：几百字符 + Error
```

然后用桌面启动器重启（它会判断"已在运行"，不会抢端口）。

---

## 第 8 步：验证

```powershell
# 1) 两个入口都应监听
Get-NetTCPConnection -LocalPort 3080,3081,18080 -State Listen | Select-Object LocalPort, LocalAddress

# 2) 隧道健康（本机看中继入口）
Invoke-WebRequest -UseBasicParsing 'http://127.0.0.1:18080/__proxy_health' | Select-Object -Expand Content

# 3) 从公网侧验证（关键：验证 frps 那一跳）
(Invoke-WebRequest -UseBasicParsing 'http://<公网IP>:18080/__proxy_health').Content

# 4) 取 token 并测会话建立
$tok = (Get-Content "$env:USERPROFILE\.dsh\lan\web-state.json" -Raw | ConvertFrom-Json).token
(Invoke-WebRequest -UseBasicParsing "http://<公网IP>:18080/?token=$tok" -MaximumRedirection 0 -ErrorAction SilentlyContinue).StatusCode
# 期望 303（重定向即代表 token 生效）
```

**手机打开**：`http://<公网IP>:18080/?token=<token>`
**成功判据**：完整 GUI + 会话列表正常 + 左下角不是"自动重连中"。

---

## 排错速查

| 现象 | 原因 | 处理 |
|---|---|---|
| 手机 **403** | 公网 IP 没进 `trustedHosts`（或只加了一处） | 第 7 步，两处都要加 |
| 手机 **401** | 地址漏了 `?token=`，或 dsh 重启后 token 变了 | 从 `web-state.json` 取新 token |
| 手机连接**超时** | 安全组没放行 18080 / frpc 没跑 | 查安全组与 `Get-Process frpc` |
| `frpc` 报 **login fail** | token 不匹配 | 比对服务器 `cat /opt/frp/frp-token` |
| `frpc` 报 **connection refused** | 7000 未放行或 frps 没起 | `systemctl status frps` |
| 本机 18080 健康、公网不通 | frps 那一跳有问题 | 服务器上 `ss -lntp \| grep 18080`、看 `/opt/frp/frps.log` |
| 页面能开但**会话列表空**、一直"自动重连中" | 代理缺 WebSocket 隧道 | 确认用的是含 `server.on('upgrade')` 的 `dsh-entry-proxy.mjs` |
| 服务器本地 `curl 127.0.0.1:18080` 不通 | frpc 没注册上隧道 | 看 frpc 输出是否 `start proxy success` |
| 到期后实例消失 | 试用到期/额度耗尽，实例自动释放，数据留 72h | 按 `docs/MIGRATION.md` 换服务器 |
