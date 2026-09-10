[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Administrator
$config = Read-YanVpnConfig
$backup = "$($script:YanVpnConfigPath).backup-$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item -LiteralPath $script:YanVpnConfigPath -Destination $backup

$hasWinNat = $false
try {
    $null = Get-CimClass -Namespace Root/StandardCimv2 -ClassName MSFT_NetNat -ErrorAction Stop
    $hasWinNat = $true
} catch {}
$routingMode = if ($hasWinNat) { 'WinNat' } else { 'Ics' }
$config | Add-Member -NotePropertyName Routing -NotePropertyValue ([pscustomobject]@{
    Mode = $routingMode
    PrivateInterface = $script:AmneziaTunnel
}) -Force
$config.WireGuard | Add-Member -NotePropertyName Enabled -NotePropertyValue $hasWinNat -Force
$config.AmneziaWG | Add-Member -NotePropertyName Enabled -NotePropertyValue $true -Force
if (-not $hasWinNat) { $config.AmneziaWG.Subnet = '192.168.137' }

if ($config.Reality.Mode -eq 'CaddyWebSocket') {
    $caddyfile = [string] $config.Reality.Caddyfile
    if (-not (Test-Path -LiteralPath $caddyfile)) { throw "Caddyfile not found: $caddyfile" }
    $caddyText = Get-Content -Raw -LiteralPath $caddyfile
    $markerStart = '# BEGIN yanvpn protocols (managed)'
    if ($caddyText -notmatch [regex]::Escape($markerStart)) {
        $globalOptions = [regex]::new('(?ms)^\{\r?\n(.*?)^\}')
        if (-not $globalOptions.IsMatch($caddyText)) { throw 'Could not find the Caddy global options block.' }
        $caddyText = $globalOptions.Replace($caddyText, {
            param($match)
            '{' + "`r`n" + $match.Groups[1].Value + "`r`n`t# BEGIN yanvpn protocols (managed)`r`n`tservers {`r`n`t`tprotocols h1 h2`r`n`t}`r`n`t# END yanvpn protocols (managed)`r`n}"
        }, 1)
        $caddyBackup = "$caddyfile.yanvpn-backup-$(Get-Date -Format yyyyMMddHHmmss)"
        Copy-Item -LiteralPath $caddyfile -Destination $caddyBackup
        [IO.File]::WriteAllText($caddyfile, $caddyText, [Text.UTF8Encoding]::new($false))
        $listener = Get-NetTCPConnection -State Listen -LocalPort 443 -ErrorAction Stop | Select-Object -First 1
        $caddyExe = (Get-CimInstance Win32_Process -Filter "ProcessId=$($listener.OwningProcess)").ExecutablePath
        & $caddyExe validate --config $caddyfile
        if ($LASTEXITCODE -ne 0) {
            Copy-Item -LiteralPath $caddyBackup -Destination $caddyfile -Force
            throw 'Caddy rejected the HTTP/1.1 + HTTP/2 configuration; the original was restored.'
        }
        & $caddyExe reload --config $caddyfile
        if ($LASTEXITCODE -ne 0) {
            Copy-Item -LiteralPath $caddyBackup -Destination $caddyfile -Force
            & $caddyExe reload --config $caddyfile | Out-Null
            throw 'Caddy reload failed; the original was restored and reloaded.'
        }
        Write-Ok 'Caddy now leaves UDP 443 to AmneziaWG while preserving HTTPS on TCP 443'
    }
}

Write-YanVpnJson $script:YanVpnConfigPath $config
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'common.ps1') -Destination (Join-Path $script:YanVpnRoot 'common.ps1') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'vpnctl.ps1') -Destination (Join-Path $script:YanVpnRoot 'vpnctl.ps1') -Force

foreach ($rule in @(
    @{ Name = 'yanvpn-wireguard'; Protocol = 'UDP'; Port = 51820 },
    @{ Name = 'yanvpn-amneziawg'; Protocol = 'UDP'; Port = 443 },
    @{ Name = 'yanvpn-reality'; Protocol = 'TCP'; Port = 443 }
)) {
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $rule.Name -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol $rule.Protocol -LocalPort $rule.Port -ErrorAction Stop | Out-Null
}

Update-ServerRuntime

if ($routingMode -eq 'WinNat') {
    if (-not (Get-NetNat -Name 'yanvpn' -ErrorAction SilentlyContinue)) {
        New-NetNat -Name 'yanvpn' -InternalIPInterfaceAddressPrefix '10.66.0.0/16' -ErrorAction Stop | Out-Null
    }
} else {
    $routingTarget = Join-Path $script:YanVpnRoot 'routing-ics.ps1'
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'routing-ics.ps1') -Destination $routingTarget -Force
    & $routingTarget
    $routingTask = 'yanvpn-routing'
    if (Get-ScheduledTask -TaskName $routingTask -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $routingTask -Confirm:$false
    }
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$routingTarget`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $routingTask -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -ErrorAction Stop | Out-Null
}

Write-Ok "Repaired yanvpn using $routingMode routing"
Write-Host "Previous configuration: $backup"
