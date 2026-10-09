[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('up','down','status','doctor','watch')][string] $Command = 'status',
    [Parameter(Position = 1)][ValidateSet('wg','awg','reality')][string] $Only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:ProgramData 'yanvpn-client'
$statePath = Join-Path $root 'state.json'
$wgExe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
$wgTool = Join-Path $env:ProgramFiles 'WireGuard\wg.exe'
$awgExe = Join-Path $env:ProgramFiles 'AmneziaWG\amneziawg.exe'
$awgTool = Join-Path $env:ProgramFiles 'AmneziaWG\awg.exe'
$singBox = Join-Path $root 'bin\sing-box.exe'
$wgName = 'yanvpn-wg'
$awgName = 'yanvpn-awg'
$realityTask = 'yanvpn-reality-client'
$watchTask = 'yanvpn-watch'
$transportsPath = Join-Path $root 'transports.json'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run yanvpn from PowerShell or Command Prompt as Administrator.'
    }
}

function Read-State {
    if (Test-Path -LiteralPath $statePath) { return (Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json) }
    [pscustomobject]@{ Wanted = $false; Last = ''; Strikes = 0 }
}

function Write-State([bool] $Wanted, [string] $Last, [int] $Strikes = 0) {
    $json = [ordered]@{ Wanted = $Wanted; Last = $Last; Strikes = $Strikes } | ConvertTo-Json
    [IO.File]::WriteAllText($statePath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
}

function Remove-Tunnel([string] $Program, [string] $Name, [string] $ServicePrefix) {
    if (Get-Service -Name "$ServicePrefix`$$Name" -ErrorAction SilentlyContinue) {
        & $Program /uninstalltunnelservice $Name | Out-Null
        Start-Sleep -Milliseconds 300
    }
}

function Stop-All {
    Remove-Tunnel $wgExe $wgName 'WireGuardTunnel'
    Remove-Tunnel $awgExe $awgName 'AmneziaWGTunnel'
    # Legacy names from before the config files were renamed to match the
    # tunnel names (the clients name a tunnel after the .conf basename, so
    # wg.conf/awg.conf used to install stray `wg`/`awg` services that this
    # function then couldn't see or remove, leaving a dead default route).
    Remove-Tunnel $wgExe 'wg' 'WireGuardTunnel'
    Remove-Tunnel $awgExe 'awg' 'AmneziaWGTunnel'
    if (Get-ScheduledTask -TaskName $realityTask -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $realityTask -ErrorAction SilentlyContinue
    }
}

function Set-WatchEnabled([bool] $Enabled) {
    $task = Get-ScheduledTask -TaskName $watchTask -ErrorAction SilentlyContinue
    if (-not $task) { return }
    if ($Enabled) {
        Enable-ScheduledTask -TaskName $watchTask -ErrorAction SilentlyContinue | Out-Null
    } else {
        Disable-ScheduledTask -TaskName $watchTask -ErrorAction SilentlyContinue | Out-Null
    }
}

function Wait-Handshake([string] $Tool, [string] $Name, [int] $Seconds = 9) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $raw = $null
        $toolExit = 1
        try {
            $raw = & $Tool show $Name latest-handshakes 2>$null
            $toolExit = $LASTEXITCODE
        } catch {}
        if ($toolExit -eq 0 -and $raw) {
            $epoch = [long] (($raw | Select-Object -First 1) -split '\s+')[-1]
            if ($epoch -gt 0) { return $true }
        }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

function Start-WireFamily([string] $Kind) {
    if ($Kind -eq 'wg') {
        $program = $wgExe; $tool = $wgTool; $name = $wgName; $prefix = 'WireGuardTunnel'; $conf = Join-Path $root 'yanvpn-wg.conf'
    } else {
        $program = $awgExe; $tool = $awgTool; $name = $awgName; $prefix = 'AmneziaWGTunnel'; $conf = Join-Path $root 'yanvpn-awg.conf'
    }
    $connected = $false
    try {
        Remove-Tunnel $program $name $prefix
        & $program /installtunnelservice $conf | Out-Null
        if ($LASTEXITCODE -ne 0) { return $false }
        $connected = (Wait-Handshake $tool $name) -and (Test-Internet 5)
    } catch {
        Write-Warning "$Kind failed: $($_.Exception.Message)"
    } finally {
        if (-not $connected) { Remove-Tunnel $program $name $prefix }
    }
    return $connected
}

function Test-Internet([int] $Timeout = 5) {
    try {
        $null = Invoke-WebRequest -UseBasicParsing -Uri 'https://api.ipify.org' -TimeoutSec $Timeout
        return $true
    } catch { return $false }
}

function Start-Reality {
    Stop-ScheduledTask -TaskName $realityTask -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $realityTask
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1
        if ((Get-ScheduledTask -TaskName $realityTask).State -eq 'Running' -and (Test-Internet 4)) { return $true }
    }
    Stop-ScheduledTask -TaskName $realityTask -ErrorAction SilentlyContinue
    return $false
}

function Get-ActiveTransport {
    if (Get-Service -Name "WireGuardTunnel`$$wgName" -ErrorAction SilentlyContinue) { return 'wg' }
    if (Get-Service -Name "AmneziaWGTunnel`$$awgName" -ErrorAction SilentlyContinue) { return 'awg' }
    $task = Get-ScheduledTask -TaskName $realityTask -ErrorAction SilentlyContinue
    if ($task -and $task.State -eq 'Running') { return 'reality' }
    return ''
}

function Connect-YanVpn([string] $OnlyTransport) {
    # A failed connection must never arm the watchdog.  This matters most for
    # full-tunnel transports: retrying one in the background can repeatedly
    # remove the user's working route before yanvpn has proved it works.
    Set-WatchEnabled $false
    Write-State $false '' 0
    Stop-All
    $enabled = if (Test-Path -LiteralPath $transportsPath) {
        Get-Content -Raw -LiteralPath $transportsPath | ConvertFrom-Json
    } else {
        [pscustomobject]@{ WireGuard = $true; AmneziaWG = $true; Reality = $true }
    }
    $order = if ($OnlyTransport) {
        @($OnlyTransport)
    } else {
        @(
            if ($enabled.AmneziaWG) { 'awg' }
            if ($enabled.WireGuard) { 'wg' }
            if ($enabled.Reality) { 'reality' }
        )
    }
    foreach ($kind in $order) {
        Write-Host "Trying $kind..." -ForegroundColor Cyan
        $ok = if ($kind -eq 'reality') { Start-Reality } else { Start-WireFamily $kind }
        if ($ok) {
            Write-State $true $kind 0
            Set-WatchEnabled $true
            Write-Host "Connected through $kind." -ForegroundColor Green
            return $true
        }
    }
    Stop-All
    Write-State $false '' 0
    Set-WatchEnabled $false
    $doctorHint = if ($OnlyTransport) { "yanvpn doctor $OnlyTransport" } else { 'yanvpn doctor' }
    Write-Warning "No transport connected. Run: $doctorHint"
    return $false
}

Assert-Administrator

switch ($Command) {
    'up' { if (-not (Connect-YanVpn $Only)) { exit 1 } }
    'down' {
        Set-WatchEnabled $false
        Stop-All
        Write-State $false '' 0
        Write-Host 'Disconnected.' -ForegroundColor Green
    }
    'status' {
        $active = Get-ActiveTransport
        if (-not $active) { Write-Host 'Disconnected.'; break }
        Write-Host "Connected through $active." -ForegroundColor Green
        try {
            $ip = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8).Trim()
            Write-Host "Exit IP: $ip"
        } catch { Write-Warning 'The tunnel is active but the public IP check failed.' }
    }
    'doctor' {
        $wasWanted = (Read-State).Wanted
        Set-WatchEnabled $false
        Stop-All
        $probeOrder = if ($Only) { @($Only) } else { @('wg','awg','reality') }
        $results = foreach ($kind in $probeOrder) {
            Write-Host "Probing $kind..." -ForegroundColor Cyan
            $ok = if ($kind -eq 'reality') { Start-Reality } else { Start-WireFamily $kind }
            [pscustomobject]@{ Transport = $kind; Result = if ($ok) { 'working' } else { 'blocked/unreachable' } }
            Stop-All
        }
        $results | Format-Table -AutoSize
        if ($wasWanted) { [void] (Connect-YanVpn '') } else { Write-State $false '' 0; Set-WatchEnabled $false }
    }
    'watch' {
        $state = Read-State
        if (-not $state.Wanted) { break }
        $active = Get-ActiveTransport
        if ($active -and (Test-Internet 6)) {
            if ($state.Strikes -ne 0) { Write-State $true $active 0 }
            break
        }
        $strikes = [int] $state.Strikes + 1
        if ($strikes -lt 2) { Write-State $true ([string] $state.Last) $strikes; break }
        [void] (Connect-YanVpn '')
    }
}
