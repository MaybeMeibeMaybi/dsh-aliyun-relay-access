# 迁移清单：换服务器 / 换电脑

本项目的设计目标之一就是**随时能重建**。因为服务器上只放可重建的东西
（frps 二进制 + 一个 token 文件），电脑侧只有两个文本配置。

---

## A. 只换服务器（电脑不动）

典型场景：阿里云免费额度到期、想换到另一家云、或服务器坏了。

**四步，约 10 分钟：**

1. **新服务器部署 frps**
   把 `src/server/aliyun-paste-command.sh` 粘贴进新服务器的控制台终端。
   记下它打印的 **公网 IP** 与 **新 token**。
   （云控制台安全组记得放行 7000、18080。）

2. **改电脑端 frpc 配置**
   编辑 `E:\DSH\dsh-hiboard\relay\frpc.toml`，只改两行：

   ```toml
   serverAddr = "<新服务器公网IP>"
   auth.token = "<新 token>"
   ```

3. **改 dsh 信任白名单**
   `~/.dsh/profiles/web/cordis.patch.yml` 的 `web-runtime` 与 `connection`
   两处 `trustedHosts`：把旧 IP 换成新 IP（**两处都要改**，否则手机 403）。

4. **重启并验证**

   ```powershell
   # 预检（只读）
   dsh --profile web --dump-config | Select-Object -First 5

   # 重启 frpc
   Get-Process frpc -ErrorAction SilentlyContinue | Stop-Process -Force
   & 'E:\DSH\dsh-hiboard\relay\frpc.exe' -c 'E:\DSH\dsh-hiboard\relay\frpc.toml'
   # 期望：login to server success / start proxy success

   # 用桌面启动器重启 dsh，然后取新 token
   (Get-Content "$env:USERPROFILE\.dsh\lan\web-state.json" -Raw | ConvertFrom-Json).token

   # 公网侧验证
   (Invoke-WebRequest -UseBasicParsing 'http://<新IP>:18080/__proxy_health').Content
   ```

> 旧服务器可直接释放，无需保留任何东西。

---

## B. 只换电脑（服务器不动）

**三步：**

1. **新电脑装好基础环境**：Node.js、`npm i -g @deepseek-ai/dsh`、`npm i -g pnpm`。
2. **按姊妹项目 `lan-remote-access/docs/DEPLOY.md` 部署**（代理 + 插件 + 启动器）。
3. **接入现有中继**：把旧电脑 `relay\frpc.toml` 拷过来（里面有 serverAddr 与 token），
   或按 A 节第 2 步重新填；再把服务器公网 IP 加进新电脑的 `cordis.patch.yml`；
   最后把 `frpc.exe` 与新写的 `shell:startup\dsh-relay-frpc.cmd` 放好。

> **不要在两台电脑上同时用同一份 `frpc.toml`**：两边都会去注册同名代理 `dsh-web`，
> 后注册的会挤掉先注册的（frps 会拒绝重复的 remotePort），导致隧道路由到不确定的一台。
> 若确实要两台共存，给它们起不同的 proxy 名并各用一个 remotePort，并在安全组放行。

---

## C. 全量迁移到一台全新电脑（含服务器重建）

1. 新电脑：Node + dsh + pnpm
2. 拷这三个项目包（`hiboard-card-sync` / `lan-remote-access` / `aliyun-relay-access`）
3. 依次执行：
   - `hiboard-card-sync/docs/DEPLOY.md`（负一屏推送，含重新填 authCode）
   - `lan-remote-access/docs/DEPLOY.md`（局域网入口）
   - `aliyun-relay-access/docs/DEPLOY.md`（公网中继）
4. 把 `~/.dsh/AGENTS.md`（全局推送规则）一并拷过去，否则功能在、但没人调用

---

## D. 迁移前自查（避免"换完才发现漏了东西"）

| 项目 | 检查命令 / 位置 |
|---|---|
| 代理脚本路径 | `cordis.patch.yml` 里 `entry-startup.proxies[].scriptPath` 指向的文件确实存在 |
| 信任白名单 | 两处 `trustedHosts` 都含当前使用的**全部** authority（LAN + 公网） |
| frpc 配置 | `serverAddr` / `auth.token` 与服务器 `cat /opt/frp/frp-token` 一致 |
| 授权码（负一屏） | `hiboard-push.config.authCode` 是最新（旧的会返回 `0000900034`） |
| 开机自启 | `shell:startup` 里有 `dsh-relay-frpc.cmd`；桌面有启动器 |
| 全局推送规则 | `~/.dsh/AGENTS.md` 存在 |
| 脚本编码 | `.cmd`/`.bat` 纯 ASCII；含非 ASCII 的 `.ps1` 必须带 UTF-8 BOM |

编码自查（两个数都应为 0，或 `.ps1` 允许非 0 但**必须带 BOM**）：

```powershell
# 一键审计（需先有 E:\DSH\_tools\Write-TextSafe.ps1）
powershell -File E:\DSH\_tools\Write-TextSafe.ps1 -Check 'E:\DSH'
```
