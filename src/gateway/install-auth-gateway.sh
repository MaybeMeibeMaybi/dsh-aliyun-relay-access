#!/usr/bin/env bash
# ============================================================================
# install-auth-gateway.sh - 在服务器上部署 HTTPS + 密码认证网关
#
# 作用：手机**只需浏览器**即可安全访问电脑上的 dsh —— 无需 SSH 客户端。
#
# 架构：
#   手机 ──https(18443)──► 本网关(密码认证 + TLS) ──► 127.0.0.1:18080
#                                                        （电脑的 SSH 反向隧道建立）
#   公网只开放 22(SSH) 与 18443(HTTPS)；18080 始终保持环回，不对外暴露。
#
# 用法：
#   sudo bash install-auth-gateway.sh [密码]
#   不给密码则自动生成一个强随机密码并打印出来。
#
# 前置：电脑侧要已经跑着 `Start-SshTunnel.ps1`（把 127.0.0.1:18080 建起来）。
# ============================================================================
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 运行"; exit 1; }

GW_DIR=/opt/dsh-gateway
GW_PORT="${GW_PORT:-18443}"

echo "==> 0) 环境检查"
command -v node >/dev/null 2>&1 || { echo "!! 需要 Node.js 18+，请先安装（apt-get install -y nodejs npm）"; exit 1; }
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
echo "    node $(node -v)  (主版本 $NODE_MAJOR)"
[ "$NODE_MAJOR" -ge 18 ] || { echo "!! Node 版本过低（需 18+），网关用到 fetch/WebCrypto"; exit 1; }

echo
echo "==> 1) 密码"
if [ "${1:-}" != "" ]; then
  GW_PASSWORD="$1"
  echo "    使用命令行提供的密码"
else
  GW_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"
  echo "    已生成随机密码"
fi

echo
echo "==> 2) 安装文件到 $GW_DIR"
mkdir -p "$GW_DIR"
# 网关脚本由部署方提供：优先用当前目录的副本，否则从参数给的路径复制
if [ -f ./dsh-auth-gateway.mjs ]; then
  install -m 0644 ./dsh-auth-gateway.mjs "$GW_DIR/dsh-auth-gateway.mjs"
elif [ -f /tmp/dsh-auth-gateway.mjs ]; then
  install -m 0644 /tmp/dsh-auth-gateway.mjs "$GW_DIR/dsh-auth-gateway.mjs"
else
  echo "!! 找不到 dsh-auth-gateway.mjs（请与本脚本放在同一目录，或先上传到 /tmp）"
  exit 1
fi
echo "    已安装 $GW_DIR/dsh-auth-gateway.mjs"

echo
echo "==> 3) TLS 证书（自签，825 天）"
if [ ! -f "$GW_DIR/cert.pem" ]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$GW_DIR/key.pem" -out "$GW_DIR/cert.pem" \
    -subj "/CN=dsh-access" -addext "subjectAltName=IP:$(curl -fsS --connect-timeout 6 https://api.ipify.org 2>/dev/null || echo 127.0.0.1)" \
    >/dev/null 2>&1
  chmod 600 "$GW_DIR/key.pem"
  echo "    已生成自签证书（含服务器公网 IP 作为 SAN）"
else
  echo "    复用已有证书"
fi

echo
echo "==> 4) 环境文件（密码不写进命令行/进程列表）"
umask 077
cat > "$GW_DIR/gateway.env" <<EOF
# dsh HTTPS 认证网关配置（权限 600）
DSH_GW_PASSWORD=${GW_PASSWORD}
DSH_GW_REGISTER_KEY_FILE=/run/dsh-gw/register-key
EOF
chmod 600 "$GW_DIR/gateway.env"
echo "    已写入 $GW_DIR/gateway.env"

echo
echo "==> 4b) token 注册密钥（供电脑上的插件上报 token 用）"
# 放在 systemd 的 RuntimeDirectory（/run/dsh-gw，权限 0700、root 专属），
# 网关以 root 运行时可读；普通用户与浏览器都拿不到它。
install -d -m 0700 /etc/dsh-gw
if [ ! -f /etc/dsh-gw/register-key ]; then
  openssl rand -hex 32 > /etc/dsh-gw/register-key
  chmod 600 /etc/dsh-gw/register-key
  echo "    已生成注册密钥（/etc/dsh-gw/register-key，600）"
else
  echo "    复用已有注册密钥"
fi
GW_REGISTER_KEY="$(cat /etc/dsh-gw/register-key)"

echo
echo "==> 5) systemd 服务"
cat > /etc/systemd/system/dsh-gateway.service <<EOF
[Unit]
Description=dsh HTTPS auth gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${GW_DIR}/gateway.env
# 注册密钥只在这个进程可见：systemd 复制到 /run/dsh-gw（0700, root）
RuntimeDirectory=dsh-gw
RuntimeDirectoryMode=0700
ExecStartPre=/bin/sh -c 'cp /etc/dsh-gw/register-key /run/dsh-gw/register-key && chmod 400 /run/dsh-gw/register-key'
ExecStart=/usr/bin/env node ${GW_DIR}/dsh-auth-gateway.mjs \\
  --bind-ip 0.0.0.0 --port ${GW_PORT} \\
  --cert ${GW_DIR}/cert.pem --key ${GW_DIR}/key.pem \\
  --backend-host 127.0.0.1 --backend-port 18080
Restart=always
RestartSec=3
# 最小权限：网关只需读自己的证书与密钥
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now dsh-gateway
sleep 3

echo
echo "==> 6) 本机验证"
if systemctl is-active --quiet dsh-gateway; then
  echo "    服务运行中"
else
  echo "    !! 服务未运行，最近日志："
  journalctl -u dsh-gateway -n 20 --no-pager || true
  exit 1
fi
echo -n "    监听: "; ss -lntp 2>/dev/null | grep ":${GW_PORT}" | awk '{print $4}' | tr '\n' ' '; echo
echo -n "    网关健康: "; curl -fsSk --max-time 6 "https://127.0.0.1:${GW_PORT}/__gw_health" || echo "(需要认证或后端未就绪)"
echo
echo -n "    后端(电脑隧道)健康: "; curl -fsS --max-time 6 http://127.0.0.1:18080/__proxy_health || echo "!! 电脑侧隧道没在跑"

echo
echo "==> 7) 防火墙"
command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && {
  ufw allow "${GW_PORT}"/tcp >/dev/null || true
  echo "    ufw 已放行 ${GW_PORT}"
}
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 && {
  firewall-cmd --permanent --add-port="${GW_PORT}"/tcp >/dev/null || true
  firewall-cmd --reload >/dev/null || true
  echo "    firewalld 已放行 ${GW_PORT}"
}

PUB="$(curl -fsS --connect-timeout 6 https://api.ipify.org 2>/dev/null || echo '<服务器公网IP>')"
cat <<EOF

============================================================
HTTPS 网关已部署
============================================================
访问地址 : https://${PUB}:${GW_PORT}/
登录密码 : ${GW_PASSWORD}

【还要做一步】阿里云安全组 → 入方向 → 放行 TCP ${GW_PORT}
（脚本改不了安全组）

手机打开时浏览器会提示"证书不受信任"（自签证书的正常现象），
选择"继续访问 / 高级 → 继续前往"即可。之后 12 小时内不用再登录。

【token 自动上报（免手工粘贴）】
  注册密钥（**只在服务器与电脑之间使用，切勿给浏览器或第三方**）：
      ${GW_REGISTER_KEY}
  密钥同时存于服务器 /etc/dsh-gw/register-key（600）
  电脑侧需要把它写到本地文件，并让 dsh-token-broadcast 插件读它：
      registerKeyPath: <电脑上的密钥文件路径>
      registerUrl:     https://${PUB}:${GW_PORT}/__gw_register

【安全说明】
  - 公网开放端口：22(SSH，仅密钥) + ${GW_PORT}(HTTPS，密码认证)
  - 18080 始终只绑 127.0.0.1，不对外暴露
  - 密码存于 ${GW_DIR}/gateway.env（权限 600）
  - 注册密钥存于 /etc/dsh-gw/register-key（600），网关运行时复制到 /run/dsh-gw（0700）
  - 改密码：编辑 ${GW_DIR}/gateway.env 后 systemctl restart dsh-gateway
  - 轮换注册密钥：rm /etc/dsh-gw/register-key 后重跑本脚本
  - 登录失败限制：每 IP 每分钟 5 次（密码与注册密钥共用）

【停用 / 卸载】
  systemctl disable --now dsh-gateway
  rm -f /etc/systemd/system/dsh-gateway.service && systemctl daemon-reload
============================================================
EOF
