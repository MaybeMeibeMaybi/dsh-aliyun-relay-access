#!/usr/bin/env bash
# ============================================================================
# relay-ssh-hardening.sh - harden the relay server and retire frps.
#
# Run on the relay server (Ubuntu/Debian) as root.
#
# What it changes:
#   1. sshd: keep key-only auth, and additionally
#        - forbid TCP forwarding *requests from clients* is NOT what we want,
#          so AllowTcpForwarding stays yes (we need the PC's reverse tunnel)
#        - GatewayPorts no  -> any reverse-forwarded port binds 127.0.0.1 only,
#          so nothing appears on the public interface
#        - X11Forwarding no / AllowAgentForwarding no -> drop capabilities we
#          never use; a stolen agent socket is a real escalation path
#        - ClientAliveInterval 30 / CountMax 3 -> reap dead tunnels after ~90s
#          (matters because the PC roams between networks)
#        - MaxAuthTries 3, LoginGraceTime 30 -> shrink the brute-force window
#   2. fail2ban: ban an IP for 1h after 5 failed SSH logins
#   3. frps: stop + disable + remove, so ports 7000 and 18080 stop existing
#   4. host firewall: clear the frp port rules; leave ssh alone
#
# Rollback is in the printed summary. Nothing here touches dsh itself.
# ============================================================================
set -euo pipefail

[ "$(id -u)" = "0" ] || { echo "run as root (sudo bash $0)"; exit 1; }

echo "==> 0) current state (for the record)"
sshd -T 2>/dev/null | grep -Ei '^(allowtcpforwarding|gatewayports|x11forwarding|allowagentforwarding|clientaliveinterval|maxauthtries)' | sed 's/^/    was: /'
ss -lntp 2>/dev/null | awk 'NR>1 && $4 !~ /^127\./ {print "    listening: "$4}' | sort -u

echo
echo "==> 1) sshd hardening"
SSHD_CONF=/etc/ssh/sshd_config.d/99-dsh-hardening.conf
mkdir -p /etc/ssh/sshd_config.d
cat > "$SSHD_CONF" <<'EOF'
# Managed by relay-ssh-hardening.sh (dsh remote-access project).
# Key-only login: the password is deliberately not a valid credential.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password

# Reverse tunnels (the PC's `ssh -R`) must never reach the public interface.
# GatewayPorts no is the default, but state it so a future edit cannot
# silently expose the relay port to the internet.
GatewayPorts no
AllowTcpForwarding yes

# Capabilities this server never needs. An agent socket on a shared host is a
# lateral-movement path, so close it.
X11Forwarding no
AllowAgentForwarding no

# Reap dead tunnels: the PC changes networks, and without these a half-open
# session can linger and hold the forwarded port.
ClientAliveInterval 30
ClientAliveCountMax 3

# Shrink the authentication window.
MaxAuthTries 3
LoginGraceTime 30
EOF
chmod 644 "$SSHD_CONF"

# Fail loud BEFORE restarting: a broken sshd config would lock us out of SSH.
if ! sshd -t; then
  echo "!! sshd -t failed - config NOT applied, nothing changed."
  rm -f "$SSHD_CONF"
  exit 1
fi
echo "    sshd -t OK"

# Keep the current session alive across the restart, then verify.
systemctl restart ssh 2>/dev/null || systemctl restart sshd
sleep 2
if ! systemctl is-active --quiet ssh 2>/dev/null && ! systemctl is-active --quiet sshd 2>/dev/null; then
  echo "!! ssh service is not active after restart - fix via the console:"
  echo "   rm $SSHD_CONF && systemctl restart ssh"
  exit 1
fi
echo "    ssh restarted and active"
sshd -T 2>/dev/null | grep -Ei '^(allowtcpforwarding|gatewayports|x11forwarding|allowagentforwarding|clientaliveinterval|maxauthtries|passwordauthentication|permitrootlogin)' | sed 's/^/    now: /'

echo
echo "==> 2) fail2ban"
if command -v fail2ban-client >/dev/null 2>&1; then
  echo "    already installed"
else
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq fail2ban >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q fail2ban >/dev/null
  else
    echo "    !! no supported package manager; skipping fail2ban"
  fi
fi
if command -v fail2ban-client >/dev/null 2>&1; then
  cat > /etc/fail2ban/jail.d/dsh-sshd.local <<'EOF'
# Managed by relay-ssh-hardening.sh
[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban || true
  sleep 2
  fail2ban-client status sshd 2>/dev/null | sed 's/^/    /' || echo "    (jail not reported yet; check: fail2ban-client status sshd)"
fi

echo
echo "==> 3) retire frps (ports 7000 / 18080 stop existing)"
if systemctl list-unit-files 2>/dev/null | grep -q '^frps\.service'; then
  systemctl stop frps 2>/dev/null || true
  systemctl disable frps 2>/dev/null || true
  echo "    frps stopped and disabled"
else
  echo "    frps unit not found (already removed?)"
fi
# The unit and config are kept so the old setup can be restored deliberately.
# Uncomment the next line to delete them instead:
# rm -f /etc/systemd/system/frps.service && systemctl daemon-reload

echo
echo "==> 4) host firewall cleanup (frp ports)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw delete allow 7000/tcp >/dev/null 2>&1 || true
  ufw delete allow 18080/tcp >/dev/null 2>&1 || true
  echo "    removed 7000/18080 from ufw"
fi
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  firewall-cmd --permanent --remove-port=7000/tcp >/dev/null 2>&1 || true
  firewall-cmd --permanent --remove-port=18080/tcp >/dev/null 2>&1 || true
  firewall-cmd --reload >/dev/null 2>&1 || true
  echo "    removed 7000/18080 from firewalld"
fi

echo
echo "==> 5) what should be listening now"
ss -lntp 2>/dev/null | awk 'NR>1 {print "    "$4" "$6}'

cat <<'EOF'

============================================================
加固完成。仍要做的一件事（网页控制台，脚本无法代劳）：

  阿里云安全组 → 入方向 → 删除这两条规则：
      TCP 7000/7000
      TCP 18080/18080
  最终只保留 22（SSH）。

之后公网上就只剩一个端口：22，且仅接受密钥登录，
并有 fail2ban 兜底。

【回滚】
  恢复 frp：systemctl enable --now frps
  再在安全组放行 7000 与 18080
  撤销 sshd 加固：rm /etc/ssh/sshd_config.d/99-dsh-hardening.conf && systemctl restart ssh
  （控制台 VNC 始终可用，作为最后通道）

【手机侧如何访问】
  手机 SSH 客户端做本地转发：
      ssh -N -L 18080:127.0.0.1:18080 root@<公网IP>
  然后浏览器打开 http://127.0.0.1:18080/?token=<dsh token>
============================================================
EOF
