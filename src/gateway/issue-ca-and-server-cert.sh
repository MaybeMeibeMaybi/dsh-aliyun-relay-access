#!/usr/bin/env bash
# ============================================================================
# issue-ca-and-server-cert.sh - 建立本地 CA，并为网关签发服务器证书
#
# 为什么不用"把自签服务器证书直接装成根证书"：
#   服务器证书有效期通常只有 1~2 年，到期换证就得让手机重新安装一次。
#   建一个 10 年有效的 CA、再用它签服务器证书，手机上只需装一次 CA，
#   以后换服务器证书（哪怕换有效期）都不必再碰手机。
#
# 产物（都在 $CA_DIR）：
#   ca-cert.pem   ← **这个装到手机上**（CA 证书，10 年）
#   ca-key.pem    ← CA 私钥，务必保密，不要外传
#   server-cert.pem / server-key.pem  ← 网关使用（由 CA 签发）
#
# 用法：
#   sudo bash issue-ca-and-server-cert.sh [额外SAN...]
#   例：sudo bash issue-ca-and-server-cert.sh 203.0.113.10 203.0.113.10.sslip.io
# ============================================================================
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 运行"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "需要 openssl"; exit 1; }

CA_DIR=/opt/dsh-gateway/ca
CA_DAYS=3650          # CA 10 年
CERT_DAYS=825         # 服务器证书（≤825 天是各平台的通行上限）
mkdir -p "$CA_DIR"
chmod 700 "$CA_DIR"

# 公网 IP：优先用参数（服务器常连不上外部探测服务，这里不做网络兜底）
PUB_IP="${1:-}"
if [ -z "$PUB_IP" ]; then
  echo "用法: sudo bash $0 <公网IP或域名> [额外SAN...]"
  echo "  例: sudo bash $0 203.0.113.10"
  exit 1
fi
shift

# 组 SAN：公网 IP + 命令行给的所有额外项
SAN="IP:${PUB_IP}"
for extra in "$@"; do
  case "$extra" in
    *[a-zA-Z]*) SAN="${SAN},DNS:${extra}" ;;
    *) SAN="${SAN},IP:${extra}" ;;
  esac
done
echo "==> 主标识: ${PUB_IP}"
echo "==> SAN   : ${SAN}"

# ---------------------------------------------------------------- 1) 建 CA
if [ ! -f "$CA_DIR/ca-key.pem" ]; then
  echo "==> 生成 CA 私钥与自签根证书（${CA_DAYS} 天）"
  openssl req -x509 -newkey rsa:4096 -nodes -days "$CA_DAYS" \
    -keyout "$CA_DIR/ca-key.pem" -out "$CA_DIR/ca-cert.pem" \
    -subj "/CN=dsh-access CA/O=dsh-local" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  chmod 600 "$CA_DIR/ca-key.pem"
  chmod 644 "$CA_DIR/ca-cert.pem"
  echo "    已创建"
else
  echo "==> CA 已存在，复用（换证不必重装手机）"
fi

# ------------------------------------------------------- 2) 签服务器证书
echo "==> 为网关签发服务器证书（${CERT_DAYS} 天）"
cat > "$CA_DIR/server-ext.cnf" <<EOF
basicConstraints=CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=${SAN}
EOF

openssl req -newkey rsa:2048 -nodes \
  -keyout "$CA_DIR/server-key.pem" -out "$CA_DIR/server.csr" \
  -subj "/CN=${PUB_IP}/O=dsh-local" 2>/dev/null

openssl x509 -req -in "$CA_DIR/server.csr" \
  -CA "$CA_DIR/ca-cert.pem" -CAkey "$CA_DIR/ca-key.pem" -CAcreateserial \
  -out "$CA_DIR/server-cert.pem" -days "$CERT_DAYS" \
  -extfile "$CA_DIR/server-ext.cnf" 2>/dev/null

chmod 600 "$CA_DIR/server-key.pem"
chmod 644 "$CA_DIR/server-cert.pem"
rm -f "$CA_DIR/server.csr"

# ------------------------------------------------------ 3) 接到网关上
echo "==> 让网关使用新证书"
install -m 0644 "$CA_DIR/server-cert.pem" /opt/dsh-gateway/cert.pem
install -m 0600 "$CA_DIR/server-key.pem" /opt/dsh-gateway/key.pem
systemctl restart dsh-gateway
sleep 3
systemctl is-active dsh-gateway | sed 's/^/    服务: /'

# ------------------------------------------------------------- 4) 自检
echo
echo "==> 证书自检"
echo -n "    CA      : "; openssl x509 -in "$CA_DIR/ca-cert.pem" -noout -subject -enddate | tr '\n' ' '; echo
echo -n "    服务器  : "; openssl x509 -in "$CA_DIR/server-cert.pem" -noout -subject -enddate | tr '\n' ' '; echo
echo -n "    SAN     : "; openssl x509 -in "$CA_DIR/server-cert.pem" -noout -ext subjectAltName | tail -1 | tr -d ' '
echo -n "    链验证  : "
if openssl verify -CAfile "$CA_DIR/ca-cert.pem" "$CA_DIR/server-cert.pem" >/dev/null 2>&1; then
  echo "通过（服务器证书确由该 CA 签发）"
else
  echo "!! 失败"
fi
echo -n "    指纹    : "; openssl x509 -in "$CA_DIR/ca-cert.pem" -noout -fingerprint -sha256 | cut -d= -f2

cat <<EOF

============================================================
证书已就绪
============================================================
【手机要安装的文件】  ← 只需装这一个
    ${CA_DIR}/ca-cert.pem

【安装步骤（华为鸿蒙）】
  1. 把这个文件传到手机（微信/QQ/数据线/云盘均可，改名为 dsh-ca.crt 更好识认）
  2. 设置 → 安全 → 更多安全设置 → 加密和凭证 → 从存储设备安装
  3. 选择「CA 证书」→ 选中 dsh-ca.crt → 确认
  4. 系统会提示"证书已安装"

【安装后】
  浏览器打开 https://${PUB_IP}:18443/ 不再有任何证书警告。

【要点】
  - CA 有效期 10 年；以后换服务器证书不必重新安装手机。
  - ${CA_DIR}/ca-key.pem 是 CA 私钥，**切勿外传**（泄露即可伪造任意网站证书）。
  - 当前服务器证书有效期 ${CERT_DAYS} 天，SAN 已包含 ${PUB_IP}。
============================================================
EOF
