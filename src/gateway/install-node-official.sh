#!/usr/bin/env bash
# ============================================================================
# install-node-official.sh - 用官方二进制包在服务器上装 Node.js（不污染系统）
#
# 为什么不走 apt：Ubuntu 22.04 仓库里只有 Node 12，项目需要 18+。
# 为什么不走 snap：会引入大量依赖与后台服务，且版本不可控。
# 官方 tarball 解压即用，卸载 = 删一个目录。
# ============================================================================
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "请用 root 或 sudo 运行"; exit 1; }

NODE_VERSION="${NODE_VERSION:-22.14.0}"
PREFIX=/opt/node
ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64) NODE_ARCH=x64 ;;
  aarch64|arm64) NODE_ARCH=arm64 ;;
  *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

TARBALL="node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz"
BASE="https://nodejs.org/dist/v${NODE_VERSION}"

echo "==> 目标: Node v${NODE_VERSION} (${NODE_ARCH}) -> ${PREFIX}"

if [ -x "${PREFIX}/bin/node" ] && "${PREFIX}/bin/node" -v 2>/dev/null | grep -q "v${NODE_VERSION}"; then
  echo "    已安装，跳过"
else
  echo "==> 下载"
  tmp="$(mktemp -d)"
  if ! curl -fsSL --retry 3 --connect-timeout 20 "${BASE}/${TARBALL}" -o "${tmp}/${TARBALL}"; then
    echo "    直连 nodejs.org 失败，改用镜像..."
    curl -fsSL --retry 3 --connect-timeout 20 "https://mirrors.tuna.tsinghua.edu.cn/nodejs-release/v${NODE_VERSION}/${TARBALL}" -o "${tmp}/${TARBALL}"
  fi
  echo "    下载完成: $(du -h "${tmp}/${TARBALL}" | cut -f1)"

  echo "==> 校验完整性（官方 SHASUMS256.txt）"
  if curl -fsSL --connect-timeout 20 "${BASE}/SHASUMS256.txt" -o "${tmp}/SHASUMS256.txt"; then
    want="$(grep " ${TARBALL}\$" "${tmp}/SHASUMS256.txt" | awk '{print $1}')"
    got="$(sha256sum "${tmp}/${TARBALL}" | awk '{print $1}')"
    if [ -n "$want" ] && [ "$want" = "$got" ]; then
      echo "    sha256 校验通过"
    else
      echo "    !! sha256 不匹配，终止（want=$want got=$got）"; exit 1
    fi
  else
    echo "    !! 无法获取 SHASUMS256.txt，跳过校验（请自行评估风险）"
  fi

  echo "==> 解压安装"
  mkdir -p "$PREFIX"
  tar -xJf "${tmp}/${TARBALL}" -C "$PREFIX" --strip-components=1
  rm -rf "$tmp"
fi

echo "==> 链接到 /usr/local/bin"
for b in node npm npx; do
  [ -e "${PREFIX}/bin/${b}" ] && ln -sf "${PREFIX}/bin/${b}" "/usr/local/bin/${b}"
done

echo "==> 验证"
echo -n "    node: "; node -v
echo -n "    npm : "; npm -v 2>/dev/null || echo "(无)"
echo -n "    路径: "; command -v node

cat <<EOF

安装完成：Node $(node -v) 位于 ${PREFIX}
卸载方式：rm -rf ${PREFIX} 以及 /usr/local/bin/{node,npm,npx}
EOF
