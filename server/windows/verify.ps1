[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Get-Content -Raw -LiteralPath (Join-Path $env:ProgramData 'yanvpn\config.json') | ConvertFrom-Json
$checks = [ordered]@{}
$awgService = Get-Service -Name 'AmneziaWGTunnel$yanvpn-awg-server' -ErrorAction SilentlyContinue
$fallbackTask = Get-ScheduledTask -TaskName 'yanvpn-reality-server' -ErrorAction SilentlyContinue
$routingTask = Get-ScheduledTask -TaskName 'yanvpn-routing' -ErrorAction SilentlyContinue
$checks['AmneziaWG service'] = $awgService -and $awgService.Status -eq 'Running'
$checks['UDP 443 listener'] = $null -ne (Get-NetUDPEndpoint -LocalPort 443 -ErrorAction SilentlyContinue | Select-Object -First 1)
$checks['HTTPS fallback task'] = $fallbackTask -and $fallbackTask.State -eq 'Running'
$checks['Fallback TCP listener'] = $null -ne (Get-NetTCPConnection -State Listen -LocalPort ([int] $config.Reality.InternalPort) -ErrorAction SilentlyContinue | Select-Object -First 1)
$checks['Routing task'] = $null -ne $routingTask

if ($config.Routing.Mode -eq 'Ics') {
    $manager = New-Object -ComObject HNetCfg.HNetShare
    $privateShared = $false
    foreach ($connection in @($manager.EnumEveryConnection())) {
        $properties = $manager.NetConnectionProps.Invoke($connection)
        $sharing = $manager.INetSharingConfigurationForINetConnection.Invoke($connection)
        if ($properties.Name -eq $config.Routing.PrivateInterface) {
            $privateShared = $sharing.SharingEnabled -and $sharing.SharingConnectionType -eq 1
        }
    }
    $checks['ICS private interface'] = $privateShared
}

$failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
foreach ($check in $checks.GetEnumerator()) {
    [pscustomobject]@{ Check = $check.Key; Result = if ($check.Value) { 'PASS' } else { 'FAIL' } }
}
if ($failed.Count) { exit 1 }
