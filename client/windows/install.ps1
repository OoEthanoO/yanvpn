[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })][string] $ClientDirectory,
    [switch] $SkipDownloads
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this installer from PowerShell as Administrator.'
    }
}

function Install-WireGuard {
    $exe = Join-Path $env:ProgramFiles 'WireGuard\wireguard.exe'
    if (Test-Path -LiteralPath $exe) { return }
    if ($SkipDownloads) { throw 'WireGuard is missing and -SkipDownloads was specified.' }
    Write-Host 'Installing official WireGuard for Windows...' -ForegroundColor Cyan
    $msi = Join-Path $env:TEMP 'wireguard-amd64-1.1.msi'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.msi' -OutFile $msi
    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', 'DO_NOT_LAUNCH=1') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "WireGuard MSI failed with exit code $($p.ExitCode)." }
}

function Install-AmneziaWG {
    $exe = Join-Path $env:ProgramFiles 'AmneziaWG\amneziawg.exe'
    if (Test-Path -LiteralPath $exe) { return }
    if ($SkipDownloads) { throw 'AmneziaWG is missing and -SkipDownloads was specified.' }
    Write-Host 'Installing official AmneziaWG for Windows...' -ForegroundColor Cyan
    $release = Invoke-RestMethod -Headers @{ 'User-Agent' = 'yanvpn' } -Uri 'https://api.github.com/repos/amnezia-vpn/amneziawg-windows-client/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match 'amd64.*\.msi$|x64.*\.msi$' } | Select-Object -First 1
    if (-not $asset) { throw 'The latest AmneziaWG release has no amd64 MSI.' }
    $msi = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $msi
    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', 'DO_NOT_LAUNCH=1') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "AmneziaWG MSI failed with exit code $($p.ExitCode)." }
}

function Install-SingBox([string] $RequiredVersion, [string] $Destination) {
    $exe = Join-Path $Destination 'sing-box.exe'
    if (Test-Path -LiteralPath $exe) { return }
    if ($SkipDownloads) { throw 'sing-box is missing and -SkipDownloads was specified.' }
    Write-Host "Installing native sing-box $RequiredVersion for Windows..." -ForegroundColor Cyan
    $assetName = "sing-box-$RequiredVersion-windows-amd64.zip"
    $url = "https://github.com/SagerNet/sing-box/releases/download/v$RequiredVersion/$assetName"
    $zip = Join-Path $env:TEMP $assetName
    $unpack = Join-Path $env:TEMP "yanvpn-sing-box-$RequiredVersion-client"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $zip
    if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack
    $source = Get-ChildItem -LiteralPath $unpack -Filter sing-box.exe -Recurse | Select-Object -First 1
    if (-not $source) { throw 'Downloaded sing-box archive did not contain sing-box.exe.' }
    Copy-Item -LiteralPath $source.FullName -Destination $exe -Force
}

Assert-Administrator
$ClientDirectory = (Resolve-Path -LiteralPath $ClientDirectory).Path
foreach ($required in 'wg.conf','awg.conf','reality.json','transports.json','sing-box-version.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $ClientDirectory $required))) { throw "$required is missing from the client directory." }
}

$root = Join-Path $env:ProgramData 'yanvpn-client'
$bin = Join-Path $root 'bin'
New-Item -ItemType Directory -Force -Path $root, $bin | Out-Null
& icacls.exe $root '/inheritance:r' '/grant:r' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not secure $root" }

Install-WireGuard
Install-AmneziaWG
$version = (Get-Content -Raw -LiteralPath (Join-Path $ClientDirectory 'sing-box-version.txt')).Trim()
Install-SingBox $version $bin

Copy-Item -LiteralPath (Join-Path $ClientDirectory 'wg.conf') -Destination (Join-Path $root 'yanvpn-wg.conf') -Force
Copy-Item -LiteralPath (Join-Path $ClientDirectory 'awg.conf') -Destination (Join-Path $root 'yanvpn-awg.conf') -Force
Copy-Item -LiteralPath (Join-Path $ClientDirectory 'reality.json') -Destination (Join-Path $root 'reality.json') -Force
Copy-Item -LiteralPath (Join-Path $ClientDirectory 'transports.json') -Destination (Join-Path $root 'transports.json') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'yanvpn.ps1') -Destination (Join-Path $root 'yanvpn.ps1') -Force

$singBox = Join-Path $bin 'sing-box.exe'
& $singBox check -c (Join-Path $root 'reality.json')
if ($LASTEXITCODE -ne 0) { throw 'The generated REALITY client configuration failed sing-box validation.' }

$taskName = 'yanvpn-reality-client'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
}
$action = New-ScheduledTaskAction -Execute $singBox -Argument "run -c `"$(Join-Path $root 'reality.json')`""
$settings = New-ScheduledTaskSettingsSet -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings -User 'SYSTEM' -RunLevel Highest -ErrorAction Stop | Out-Null

$watchName = 'yanvpn-watch'
if (Get-ScheduledTask -TaskName $watchName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $watchName -Confirm:$false
}
$watchAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $root 'yanvpn.ps1')`" watch"
$watchTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
$watchSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $watchName -Action $watchAction -Trigger $watchTrigger -Settings $watchSettings -User 'SYSTEM' -RunLevel Highest | Out-Null

$cmdDir = Join-Path $env:ProgramFiles 'yanvpn'
New-Item -ItemType Directory -Force -Path $cmdDir | Out-Null
$cmdPath = Join-Path $cmdDir 'yanvpn.cmd'
$cmdBody = '@echo off' + "`r`n" + 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%ProgramData%\yanvpn-client\yanvpn.ps1" %*' + "`r`n"
[IO.File]::WriteAllText($cmdPath, $cmdBody, [Text.Encoding]::ASCII)
$machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
if (($machinePath -split ';') -notcontains $cmdDir) {
    [Environment]::SetEnvironmentVariable('Path', ($machinePath.TrimEnd(';') + ';' + $cmdDir), 'Machine')
}
[IO.File]::WriteAllText((Join-Path $root 'state.json'), '{"Wanted":false,"Last":"","Strikes":0}', [Text.Encoding]::ASCII)

Write-Host ''
Write-Host 'yanvpn Windows client is installed.' -ForegroundColor Green
Write-Host 'Open a new Administrator terminal, then run:'
Write-Host '  yanvpn up'
Write-Host '  yanvpn status'
Write-Host '  yanvpn doctor'
Write-Host '  yanvpn down'
