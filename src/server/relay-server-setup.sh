#!/usr/bin/env bash
# ============================================================================
# relay-server-setup.sh — 在云服务器（中继）上部署 frps 反向代理
#
# 作用：给"电脑处在随机网络、手机随时要连"的场景提供一个固定公网入口。
#       电脑跑 frpc 主动连出到本服务器，手机访问服务器的公网端口即可到达
#       电脑上的 dsh web（127.0.0.1:3080）。
#
# 适用：Ubuntu / Debian（x86_64 或 aarch64 自动识别）
# 用法：sudo bash relay-server-setup.sh
#
# 安全设计：
#   - frps 只开放一个端口（默认 7000）给电脑连入，且强制 token 鉴权
#   - 手机侧访问的端口（默认 18080）只转发到电脑的 dsh web
#   - dsh 自身的会话鉴权（token）仍然生效，未持有 token 一律 401/403
# ============================================================================
set -euo pipefail

FRP_VERSION="${FRP_VERSION:-0.61.1}"
FRP_DIR="/opt/frp"
BIND_PORT="${BIND_PORT:-7000}"        # 电脑 frpc 连入的端口
DASH_PORT="${DASH_PORT:-7500}"        # frps 管理面板（仅本机）
WEB_PORT="${WEB_PORT:-18080}"         # 手机侧访问端口 -> 电脑 127.0.0.1:3080
TOKEN_FILE="/opt/frp/frp-token"

need_root() { [ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 运行"; exit 1; }; }
need_root

arch="$(uname -m)"
case "$arch" in
  x86_64|amd64) frp_arch="amd64" ;;
  aarch64|arm64) frp_arch="arm64" ;;
  *) echo "暂不支持的架构: $arch"; exit 1 ;;
esac
echo "==> 架构: $arch -> $frp_arch"

echo "==> 安装依赖"
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq curl tar openssl >/dev/null
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q curl tar openssl >/dev/null
else
  echo "未识别的包管理器，请手动安装 curl/tar/openssl"; exit 1
fi

echo "==> 下载 frp v${FRP_VERSION}"
mkdir -p "$FRP_DIR"
tmp="$(mktemp -d)"
tarball="frp_${FRP_VERSION}_linux_${frp_arch}.tar.gz"
url="https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/${tarball}"
echo "    $url"
if ! curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$tmp/$tarball"; then
  echo "!! 下载失败：GitHub 在国内服务器上常被限速/阻断。"
  echo "   可改用镜像，例如："
  echo "   curl -fsSL https://mirror.ghproxy.com/$url -o $tmp/$tarball"
  exit 1
fi
tar -xzf "$tmp/$tarball" -C "$tmp"
install -m 0755 "$tmp/frp_${FRP_VERSION}_linux_${frp_arch}/frps" "$FRP_DIR/frps"
rm -rf "$tmp"

echo "==> 生成鉴权 token（仅首次）"
if [ ! -f "$TOKEN_FILE" ]; then
  openssl rand -hex 24 > "$TOKEN_FILE"
  chmod 600 "$TOKEN_FILE"
  echo "    已生成: $TOKEN_FILE"
else
  echo "    复用已有: $TOKEN_FILE"
fi
FRP_TOKEN="$(cat "$TOKEN_FILE")"

echo "==> 写配置 $FRP_DIR/frps.toml"
cat > "$FRP_DIR/frps.toml" <<EOF
# frps 服务端配置（由 relay-server-setup.sh 生成）
bindPort = ${BIND_PORT}

# 电脑侧 frpc 必须带同样的 token 才能注册
auth.method = "token"
auth.token = "${FRP_TOKEN}"

# 管理面板只监听本机，避免暴露
webServer.addr = "127.0.0.1"
webServer.port = ${DASH_PORT}
webServer.user = "admin"
webServer.password = "$(openssl rand -hex 12)"

# 只允许 frpc 申请我们预期的端口范围，防止滥用
allowPorts = [
  { start = ${WEB_PORT}, end = ${WEB_PORT} }
]

log.to = "${FRP_DIR}/frps.log"
log.level = "info"
log.maxDays = 7
EOF
chmod 600 "$FRP_DIR/frps.toml"

echo "==> 安装 systemd 服务"
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server (relay for dsh web)
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
systemctl --no-pager --full status frps | head -20

echo "==> 放行防火墙端口（如启用了 ufw/firewalld）"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${BIND_PORT}"/tcp >/dev/null || true
  ufw allow "${WEB_PORT}"/tcp >/dev/null || true
  echo "    ufw 已放行 ${BIND_PORT} 与 ${WEB_PORT}"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --add-port="${BIND_PORT}"/tcp >/dev/null || true
  firewall-cmd --permanent --add-port="${WEB_PORT}"/tcp >/dev/null || true
  firewall-cmd --reload >/dev/null || true
  echo "    firewalld 已放行 ${BIND_PORT} 与 ${WEB_PORT}"
fi

public_ip="$(curl -fsSL --connect-timeout 8 https://api.ipify.org || echo '<你的服务器公网IP>')"

cat <<EOF

============================================================
frps 部署完成
============================================================
公网 IP        : ${public_ip}
frpc 连接端口  : ${BIND_PORT}
手机访问端口   : ${WEB_PORT}

【电脑侧需要的信息】
  serverAddr = ${public_ip}
  serverPort = ${BIND_PORT}
  token      = ${FRP_TOKEN}

注意：token 等同于中继的钥匙，请勿发到群聊或提交到仓库。
============================================================
⚠️ 云厂商控制台的安全组 / 防火墙也要放行 ${BIND_PORT} 和 ${WEB_PORT}！
   （这一步在网页控制台做，脚本无法代劳）
============================================================
EOF
