# ============================================================================
# ssh-key-setup.ps1 - switch the relay server to SSH key login (Windows side)
#
# Prerequisite: the public key is already installed on the server in
#   /root/.ssh/authorized_keys   (paste it once via the cloud console terminal;
#   the one-liner is in docs/DEPLOY.md step 6).
#
# Usage:
#   powershell -File .\ssh-key-setup.ps1 -SshHost <server-ip>            # test key login
#   powershell -File .\ssh-key-setup.ps1 -SshHost <server-ip> -Harden    # then disable password login
#
# IMPORTANT: keep this file ASCII-only. PowerShell 5.1 decodes .ps1 as ANSI when
# there is no BOM, so non-ASCII text becomes mojibake and breaks parsing.
# ============================================================================
param(
    [Parameter(Mandatory = $true)][string]$SshHost,
    [string]$SshUser = 'root',
    [string]$KeyPath = (Join-Path $env:USERPROFILE '.ssh\dsh_relay'),
    [switch]$Harden
)

$ErrorActionPreference = 'Continue'

$SshExe = 'C:\WINDOWS\System32\OpenSSH\ssh.exe'
$Common = @('-i', $KeyPath, '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=15', '-o', 'PreferredAuthentications=publickey')

function Say($t) { Write-Host $t }

if (-not (Test-Path $KeyPath)) {
    Say "[x] private key not found: $KeyPath"
    Say "    Pass -KeyPath, or place the .pem there first."
    exit 1
}

Say "==> 1) test key login to $SshUser@$SshHost"
$out = & $SshExe @Common "$SshUser@$SshHost" "echo KEY_AUTH_OK; hostname; whoami" 2>&1
$text = ($out | Out-String).Trim()
Say $text

if ($text -notmatch 'KEY_AUTH_OK') {
    Say ''
    Say "[x] key login is not active yet. Install the public key on the server first"
    Say "    (see docs/DEPLOY.md step 6), then re-run."
    exit 1
}

Say ''
Say "[+] key login works."

# ------------------------------------------------------------- client config
# Add a ~/.ssh/config entry so plain `ssh dsh-relay` works without -i.
# NOTE: the IdentityFile value is QUOTED because a Windows profile path often
# contains a space ("Jim Chen"); unquoted, ssh reports
#   "keyword identityfile extra arguments at end of line"
# and refuses to start at all.
$cfgPath = Join-Path $env:USERPROFILE '.ssh\config'
$marker  = '# --- dsh-relay (added by ssh-key-setup.ps1) ---'
$block = @"
$marker
Host dsh-relay
    HostName $SshHost
    User $SshUser
    IdentityFile "$KeyPath"
    IdentitiesOnly yes
    ServerAliveInterval 30
# --- end dsh-relay ---
"@

if (Test-Path $cfgPath) {
    $existing = Get-Content $cfgPath -Raw
    if ($existing -match [regex]::Escape($marker)) {
        $pattern = "(?s)" + [regex]::Escape($marker) + ".*?" + [regex]::Escape('# --- end dsh-relay ---')
        $fixed = [regex]::Replace($existing, $pattern, $block)
        if ($fixed -ne $existing) {
            Set-Content -Path $cfgPath -Value $fixed -Encoding ASCII -NoNewline
            Say "[+] repaired the dsh-relay entry in $cfgPath (quoted IdentityFile)."
        } else {
            Say "[=] $cfgPath already has a correct dsh-relay entry."
        }
    } else {
        Add-Content -Path $cfgPath -Value "`r`n$block`r`n" -Encoding ASCII
        Say "[+] wrote $cfgPath - you can now use: ssh dsh-relay"
    }
} else {
    Set-Content -Path $cfgPath -Value "$block`r`n" -Encoding ASCII -NoNewline
    Say "[+] created $cfgPath - you can now use: ssh dsh-relay"
}

if (-not $Harden) {
    Say ''
    Say "Next step (once key login is confirmed stable):"
    Say "    powershell -File .\ssh-key-setup.ps1 -SshHost $SshHost -Harden"
    exit 0
}

# ------------------------------------------------------- disable password auth
Say ''
Say "==> 2) disable password login (keep key login)"
$remote = @'
set -e
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/99-dsh-hardening.conf <<'EOF'
# Added by dsh ssh-key-setup.ps1
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
EOF
sshd -t
systemctl restart ssh 2>/dev/null || systemctl restart sshd
echo HARDEN_APPLIED
'@
$out2 = & $SshExe @Common "$SshUser@$SshHost" $remote 2>&1
Say ($out2 | Out-String).Trim()

Say ''
Say "==> 3) re-verify key login still works (do not lock yourself out)"
$out3 = & $SshExe @Common "$SshUser@$SshHost" "echo STILL_OK" 2>&1
$text3 = ($out3 | Out-String).Trim()
Say $text3
if ($text3 -match 'STILL_OK') {
    Say ''
    Say "[+] done: key login works, password login is disabled."
    Say "    The console VNC connection still works as a last resort."
} else {
    Say ''
    Say "[!] verification FAILED - recover immediately via the console VNC:"
    Say "    rm /etc/ssh/sshd_config.d/99-dsh-hardening.conf && systemctl restart ssh"
    exit 1
}
