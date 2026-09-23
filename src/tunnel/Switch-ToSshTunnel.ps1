# ============================================================================
# Switch-ToSshTunnel.ps1 - retire frpc on this PC and start the SSH tunnel.
#
# Order matters: frpc currently owns the public port through frps. We stop frps
# first (already done on the server), then:
#   1. stop frpc and stop it coming back (Startup entry + scheduled task if any)
#   2. start the reverse SSH tunnel, which creates 127.0.0.1:<port> ON THE SERVER
#   3. verify from the server side and locally
#
# ASCII-only on purpose. PowerShell 5.1 reads .ps1 as ANSI without a BOM.
# ============================================================================
[CmdletBinding()]
param(
    [string]$SshTarget = 'dsh-aliyun',
    [int]$RemotePort = 18080,
    [int]$LocalPort = 18080
)

$ErrorActionPreference = 'Continue'
function Say($m) { Write-Host $m }

Say "=== 1) stop frpc and stop it from coming back ==="
# NOTE: no pipe/redirect around taskkill - capturing a native process's output
# through a pipe is blocked in this environment.
if (Get-Process frpc -ErrorAction SilentlyContinue) {
    taskkill /IM frpc.exe /F
    Say "  frpc stopped"
} else {
    Say "  frpc was not running"
}

$startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\dsh-relay-frpc.cmd'
if (Test-Path $startup) {
    Remove-Item $startup -Force
    Say "  removed Startup entry: dsh-relay-frpc.cmd"
} else {
    Say "  no Startup entry for frpc"
}

# The old launcher also re-started frpc on every run (its watchdog block).
# Neutralise that by pointing the relay dir name check at nothing: rename the exe
# so a stale launcher cannot start it, while keeping it for rollback.
$relayDir = 'E:\DSH\dsh-hiboard\relay'
$frpcExe = Join-Path $relayDir 'frpc.exe'
if (Test-Path $frpcExe) {
    Rename-Item $frpcExe 'frpc.exe.disabled' -Force
    Say "  renamed frpc.exe -> frpc.exe.disabled (kept for rollback)"
}

Say ""
Say "=== 2) start the reverse SSH tunnel (detached) ==="
$script = Join-Path $PSScriptRoot 'Start-SshTunnel.ps1'
if (-not (Test-Path $script)) { Say "  [fail] Start-SshTunnel.ps1 not found next to this script"; exit 1 }
$p = Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $script,
                    '-SshTarget', $SshTarget, '-RemotePort', "$RemotePort", '-LocalPort', "$LocalPort") `
    -PassThru -WindowStyle Hidden
Say "  supervisor started, pid $($p.Id)"
Start-Sleep -Seconds 8

$sshProcs = Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*-R ${RemotePort}:*" }
if ($sshProcs) {
    Say "  tunnel ssh process: pid $($sshProcs[0].ProcessId)"
} else {
    Say "  [warn] no tunnel ssh process found - check the log:"
    Say "         $env:USERPROFILE\.dsh\lan\ssh-tunnel.log"
}

Say ""
Say "=== 3) local entry proxy still listening? ==="
$c = Get-NetTCPConnection -LocalPort $LocalPort -State Listen -ErrorAction SilentlyContinue
if ($c) { Say "  127.0.0.1:$LocalPort LISTEN (owned by pid $($c.OwningProcess))" }
else { Say "  [fail] nothing on $LocalPort - the dsh-entry-startup proxy is not running" }
