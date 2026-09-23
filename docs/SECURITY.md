# 安全：凭据、暴露面与加固

本项目把一台公网服务器接到你家电脑上，因此安全边界必须清楚。

---

## 1. 三道防线（缺一不可）

```
手机 ──► 公网:18080 ──► frps(token 鉴权) ──► 隧道 ──► 电脑代理 ──► dsh(会话 token)
             ①安全组                ②frp token              ③dsh token
```

| 防线 | 保护什么 | 失效后果 |
|---|---|---|
| ① 安全组只放行 7000/18080 | 减少暴露面 | 无关端口被扫 |
| ② frps `auth.token` | 防止陌生人往你的隧道注册代理 | 他人可占用你的入口端口 |
| ③ dsh 会话 token + 信任围栏 | 真正的访问控制 | 未授权访问 GUI |

关键认识：**入口代理不是鉴权层**。它只负责转发。真正拦人的是 ③。
所以 ② 和 ③ 的凭据都必须当作钥匙保管。

---

## 2. 凭据清单与保管

| 凭据 | 位置 | 泄露后果 | 轮换方式 |
|---|---|---|---|
| frp token | 服务器 `/opt/frp/frp-token`（600）；电脑 `relay\frpc.toml` | 他人可注册同名代理占用 18080 | 删掉该文件重跑 `relay-server-setup.sh`（会重新生成），再改电脑端 `frpc.toml` |
| dsh 会话 token | 每次启动 dsh 随机生成，仅打印一次；启动器存到 `~/.dsh/lan/web-state.json` | 拿到即可访问 GUI | **重启 dsh 即自动更换** |
| 云服务器 root 密码 / 私钥 | 你自己保管；私钥放 `~/.ssh/` 并收紧权限 | 服务器被完全接管 | 控制台重置密码 / 更换密钥对 |
| 负一屏 authCode（姊妹项目） | `~/.dsh/profiles/web/cordis.patch.yml` | 他人可往你负一屏推卡片 | 负一屏重新取码 |

> 本项目的文档与示例中，所有真实凭据一律以 `<FRP_TOKEN>` / `<AUTH_CODE>` / `<RELAY_HOST>`
> 占位，**不要把填好真实值的文件提交到仓库或发到群里**。

---

## 3. SSH 加固（推荐）

阿里云 Ubuntu 镜像默认 **`PasswordAuthentication no`**，所以密码其实并不用于 SSH。
真正的加固点是 `PermitRootLogin`：默认 `yes` 允许 root 用密码登录，应改为 `prohibit-password`。

用 `src/client/ssh-key-setup.ps1`：

```powershell
# 1) 装好公钥后先测试
powershell -File .\ssh-key-setup.ps1 -SshHost <公网IP> -KeyPath <私钥路径>

# 2) 稳定后再加固（关密码、保留密钥）
powershell -File .\ssh-key-setup.ps1 -SshHost <公网IP> -KeyPath <私钥路径> -Harden
```

加固写入 `/etc/ssh/sshd_config.d/99-dsh-hardening.conf`：

```
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
```

脚本会 `sshd -t` 校验语法 → 重启服务 → **立即复验密钥登录**。
若复验失败，脚本会打印用控制台 VNC 执行的回滚命令：

```bash
rm /etc/ssh/sshd_config.d/99-dsh-hardening.conf && systemctl restart ssh
```

**控制台 VNC「远程连接」始终是最后的救急通道**，任何时候都能用它恢复 SSH 配置。

---

## 4. 已知风险与缓解

| 风险 | 说明 | 缓解 |
|---|---|---|
| 公网端口被扫描 | 18080 对外开放，会被扫到 | 未持 token 一律 401/403；必要时改用非标端口或加 IP 白名单 |
| token 写在聊天/日志里 | 会话记录是明文落盘（如 `~/.dsh/sessions`） | 泄露后立即重启 dsh（换 token）/ 重生成 frp token |
| 明文 HTTP | 手机到服务器的流量未加密，同链路可嗅探 token | 可加自签 TLS，或用 SSH 端口转发代替（`ssh -L`）；frpc 已开启 `transport.useEncryption`（隧道段加密） |
| 服务器被入侵 | 中继上只有 frps 与一个 token 文件 | 定期 `apt upgrade`；不使用弱密码；只开必要端口 |
| 免费额度到期 | 实例被释放，公网入口消失 | 见 `MIGRATION.md`，四步迁移 |

---

## 5. 关闭或降级通道

| 目的 | 操作 |
|---|---|
| 只关公网、保留局域网 | `Stop-Process -Name frpc`（局域网 3081 不受影响） |
| 只关中继入口、保留隧道 | 在 `cordis.patch.yml` 的 `entry-startup.proxies` 里删掉 `relay-proxy` 那条 |
| 全部关闭远程访问 | 删掉 `web-runtime`/`connection` 的 `trustedHosts`，重启 dsh |
| 彻底销毁中继 | 控制台释放实例；电脑端停掉并删除 frpc 启动项 |

---

## 6. 定期自查清单

```powershell
# 1) 暴露面：公网只应有 7000/18080（在服务器上执行）
#    ss -lntp | grep -v 127.0.0.1

# 2) 可信主机白名单是否只含你认识的两个地址
Select-String -Path "$env:USERPROFILE\.dsh\profiles\web\cordis.patch.yml" -Pattern 'trustedHosts' -Context 0,4

# 3) frpc 是否在跑、隧道是否正常
Get-Process frpc -ErrorAction SilentlyContinue
Get-Content 'E:\DSH\dsh-hiboard\relay\frpc.log' -Tail 5

# 4) 私钥权限是否仍只有你本人可读
icacls "$env:USERPROFILE\.ssh\dsh_relay"
```
