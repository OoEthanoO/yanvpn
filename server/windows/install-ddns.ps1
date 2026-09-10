[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string] $Subdomain,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Token
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Administrator
$config = Read-YanVpnConfig

$ddnsConfig = Join-Path $script:YanVpnRoot 'duckdns.json'
$ddnsScript = Join-Path $script:YanVpnRoot 'update-duckdns.ps1'
Write-YanVpnJson $ddnsConfig ([ordered]@{ Subdomain = $Subdomain; Token = $Token })

$body = @'
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:ProgramData 'yanvpn'
$settings = Get-Content -Raw -LiteralPath (Join-Path $root 'duckdns.json') | ConvertFrom-Json
$uri = 'https://www.duckdns.org/update?domains={0}&token={1}&ip=' -f [Uri]::EscapeDataString($settings.Subdomain), [Uri]::EscapeDataString($settings.Token)
$result = (Invoke-RestMethod -Uri $uri -TimeoutSec 15).Trim()
if ($result -ne 'OK') { throw "DuckDNS returned: $result" }
'@
[IO.File]::WriteAllText($ddnsScript, $body, [Text.UTF8Encoding]::new($false))

& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ddnsScript
if ($LASTEXITCODE -ne 0) { throw 'The first DuckDNS update failed; no task was installed.' }

$taskName = 'yanvpn-duckdns'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$ddnsScript`""
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest | Out-Null

$config.Endpoint = "$Subdomain.duckdns.org"
Write-YanVpnJson $script:YanVpnConfigPath $config
foreach ($client in Get-ClientRecords) { Write-ClientFiles $config $client }

Write-Ok "DuckDNS is updating $Subdomain.duckdns.org every five minutes."
Write-Warn 'Existing client profiles must be reinstalled or rescanned because their endpoint changed.'
