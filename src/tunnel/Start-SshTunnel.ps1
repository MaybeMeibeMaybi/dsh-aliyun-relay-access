# ============================================================================
# Start-SshTunnel.ps1 - keep a reverse SSH tunnel alive (replaces frpc).
#
# What it does:
#   ssh -N -R 18080:127.0.0.1:18080 dsh-aliyun
#
#   The relay server ends up with port 18080 bound to 127.0.0.1 ONLY (no bind
#   address is requested, so sshd uses its default and GatewayPorts is not
#   needed). Nothing on the public internet can reach it - the only host that
#   can is someone already logged into the server over SSH.
#
# Why this replaces frp:
#   * no extra public port: 7000 and 18080 can both be closed in the security
#     group, leaving only SSH (22) exposed
#   * the phone -> server hop is encrypted by SSH (frp carried plain HTTP there)
#   * one daemon fewer: no frps service on the server, no frpc on the PC
#
# Usage:
#   powershell -File Start-SshTunnel.ps1                 # run in foreground, auto-restart
#   powershell -File Start-SshTunnel.ps1 -Once           # single attempt, for testing
#   powershell -File Start-SshTunnel.ps1 -RemotePort 8080
#
# ASCII-only on purpose: PowerShell 5.1 decodes .ps1 as ANSI when there is no
# BOM, so non-ASCII text becomes mojibake and breaks parsing.
# ============================================================================
[CmdletBinding()]
param(
    [string]$SshTarget = 'dsh-aliyun',   # ~/.ssh/config alias of the relay server
    [int]$RemotePort = 18080,            # port created on the relay server (loopback only)
    [int]$LocalPort = 18080,             # local entry proxy that dsh-entry-startup runs
    [switch]$Once
)

$ErrorActionPreference = 'Continue'
$SshExe = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$logDir = Join-Path $env:USERPROFILE '.dsh\lan'
$log = Join-Path $logDir 'ssh-tunnel.log'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Log([string]$m) {
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $log -Value $line -ErrorAction SilentlyContinue
    Write-Host $line
}

if (-not (Test-Path $SshExe)) { Log "[fail] ssh.exe not found: $SshExe"; exit 1 }

# Refuse to start twice: two tunnels fighting over the same remote port makes
# sshd kill the older one, which looks like a random disconnect.
$existing = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*-R ${RemotePort}:*" }
if ($existing -and -not $Once) {
    Log "[skip] a tunnel for remote port $RemotePort is already running (pid $($existing[0].ProcessId))"
    exit 0
}

# -N            no remote command, tunnel only
# -R            reverse forward: server:$RemotePort -> this PC's 127.0.0.1:$LocalPort
# -o ExitOnForwardFailure=yes  fail fast if the remote port is taken, instead of
#                              running without a tunnel
# -o ServerAliveInterval/CountMax  detect a dead link (network switch) quickly
# -o BatchMode=yes  never prompt; key auth only
$sshArgs = @(
    '-N',
    '-R', "${RemotePort}:127.0.0.1:${LocalPort}",
    '-o', 'ExitOnForwardFailure=yes',
    '-o', 'ServerAliveInterval=20',
    '-o', 'ServerAliveCountMax=3',
    '-o', 'ConnectTimeout=15',
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=accept-new',
    $SshTarget
)

Log "starting reverse tunnel: server 127.0.0.1:$RemotePort -> local 127.0.0.1:$LocalPort  (target $SshTarget)"

if ($Once) {
    & $SshExe @sshArgs
    Log "[exit] single attempt finished with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

# Supervisor loop: the PC roams between networks, so the tunnel WILL drop.
# Restart it with a short backoff instead of relying on a human.
$attempt = 0
while ($true) {
    $proc = Start-Process -FilePath $SshExe -ArgumentList $sshArgs -PassThru -NoNewWindow `
        -RedirectStandardError (Join-Path $logDir 'ssh-tunnel.err.log')
    Log "tunnel process started, pid $($proc.Id)"
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $attempt++
    $wait = [Math]::Min(30, 3 + $attempt * 2)   # 5s, 7s, ... capped at 30s
    Log "[warn] tunnel exited (code $code); reconnecting in ${wait}s (attempt $attempt)"
    Start-Sleep -Seconds $wait
}
