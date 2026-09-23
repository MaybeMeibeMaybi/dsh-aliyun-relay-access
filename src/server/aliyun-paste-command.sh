#!/usr/bin/env bash
# ============================================================================
# 阿里云服务器 · frps 一键部署（自包含版，直接粘贴到「远程连接」里执行）
#
# 做的事：装依赖 -> 下载 frp -> 生成 token -> 写配置 -> systemd 开机自启
#         -> 放行本机防火墙 -> 打印 公网IP/端口/token
#
# 用法：把本文件全部内容复制，粘贴进阿里云控制台的「远程连接」终端（root 身份），回车。
# ============================================================================
set -euo pipefail

FRP_VERSION=0.61.1
FRP_DIR=/opt/frp
BIND_PORT=7000      # 电脑上的 frpc 连入
WEB_PORT=18080      # 手机从公网访问
DASH_PORT=7500      # 管理面板，仅本机

arch=$(uname -m)
case "$arch" in
  x86_64|amd64) a=amd64 ;;
  aarch64|arm64) a=arm64 ;;
  *) echo "不支持的架构: $arch"; exit 1 ;;
esac
echo "==> 架构 $arch -> $a"

echo "==> 安装依赖"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq curl tar openssl >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl tar openssl >/dev/null
else
  echo "未识别包管理器"; exit 1
fi

mkdir -p "$FRP_DIR"
tmp=$(mktemp -d)
tb="frp_${FRP_VERSION}_linux_${a}.tar.gz"
url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${tb}"

echo "==> 下载 frp"
if ! curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$tmp/$tb"; then
  echo "GitHub 直连失败，改用镜像..."
  curl -fsSL --retry 3 --connect-timeout 20 "https://mirror.ghproxy.com/$url" -o "$tmp/$tb"
fi
tar -xzf "$tmp/$tb" -C "$tmp"
install -m 0755 "$tmp/frp_${FRP_VERSION}_linux_${a}/frps" "$FRP_DIR/frps"
rm -rf "$tmp"

echo "==> 生成 token"
if [ ! -f "$FRP_DIR/frp-token" ]; then
  openssl rand -hex 24 > "$FRP_DIR/frp-token"
  chmod 600 "$FRP_DIR/frp-token"
fi
TOKEN=$(cat "$FRP_DIR/frp-token")

echo "==> 写配置"
cat > "$FRP_DIR/frps.toml" <<EOF
bindPort = ${BIND_PORT}
auth.method = "token"
auth.token = "${TOKEN}"
webServer.addr = "127.0.0.1"
webServer.port = ${DASH_PORT}
webServer.user = "admin"
webServer.password = "$(openssl rand -hex 12)"
allowPorts = [ { start = ${WEB_PORT}, end = ${WEB_PORT} } ]
log.to = "${FRP_DIR}/frps.log"
log.level = "info"
log.maxDays = 7
EOF
chmod 600 "$FRP_DIR/frps.toml"

echo "==> 安装 systemd 服务"
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server (dsh relay)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${FRP_DIR}/frps -c ${FRP_DIR}/frps.toml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now frps
sleep 2

echo "==> 本机防火墙放行"
command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active" && { ufw allow ${BIND_PORT}/tcp || true; ufw allow ${WEB_PORT}/tcp || true; }
command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1 && { firewall-cmd --permanent --add-port=${BIND_PORT}/tcp || true; firewall-cmd --permanent --add-port=${WEB_PORT}/tcp || true; firewall-cmd --reload || true; }

echo
echo "============ 服务状态 ============"
systemctl is-active frps
ss -lntp 2>/dev/null | grep -E ":${BIND_PORT}|:${WEB_PORT}" || echo "(未看到监听，请把上面 systemctl 的输出发给我)"

PUB=$(curl -fsSL --connect-timeout 8 https://api.ipify.org 2>/dev/null || echo "<SERVER_PUBLIC_IP>")
echo
echo "============ 请把下面三行复制发给我 ============"
echo "公网IP   : ${PUB}"
echo "连接端口 : ${BIND_PORT}"
echo "token    : ${TOKEN}"
echo "=============================================="
echo "另外请确认：阿里云控制台安全组已放行 TCP ${BIND_PORT} 与 ${WEB_PORT}"
