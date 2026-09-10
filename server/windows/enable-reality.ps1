[CmdletBinding()]
param([ValidateRange(1024,65535)][int] $Port = 8443)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Administrator
$config = Read-YanVpnConfig
if ($config.Reality.Mode -notin @('CaddyWebSocket','Dual')) {
    throw 'This helper is for a Caddy-hosted Windows installation.'
}

$backup = "$($script:YanVpnConfigPath).backup-$(Get-Date -Format yyyyMMddHHmmss)"
Copy-Item -LiteralPath $script:YanVpnConfigPath -Destination $backup
$config.Reality.Mode = 'Dual'
$config.Reality.Port = $Port
$config.Reality | Add-Member -NotePropertyName WebSocketPort -NotePropertyValue 443 -Force
Write-YanVpnJson $script:YanVpnConfigPath $config

foreach ($client in Get-ClientRecords) { Write-ClientFiles $config $client }
$realityConfig = Join-Path $script:YanVpnRoot 'reality-server.json'
Write-YanVpnJson $realityConfig (Get-RealityServerConfig $config)
Invoke-Checked $script:SingBoxExe check -c $realityConfig
Register-RealityTask $realityConfig
Start-ScheduledTask -TaskName $script:RealityTask -ErrorAction Stop
Start-Sleep -Seconds 2

Remove-NetFirewallRule -Name 'yanvpn-reality-direct' -ErrorAction SilentlyContinue
New-NetFirewallRule -Name 'yanvpn-reality-direct' -DisplayName 'yanvpn VLESS REALITY' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -ErrorAction Stop | Out-Null

$listener = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $listener) { throw "sing-box did not start listening on TCP $Port." }
Write-Ok "VLESS + REALITY is listening on TCP $Port"
Write-Host "Previous configuration: $backup"
