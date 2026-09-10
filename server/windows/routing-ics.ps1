[CmdletBinding()]
param([switch] $Disable)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Join-Path $env:ProgramData 'yanvpn'
$config = Get-Content -Raw -LiteralPath (Join-Path $root 'config.json') | ConvertFrom-Json
if ($config.Routing.Mode -ne 'Ics') { exit 0 }

function Clear-StaleIcsState {
    try {
        $scope = New-Object System.Management.ManagementScope('root\Microsoft\HomeNet')
        $scope.Connect()
        $query = New-Object System.Management.ObjectQuery('SELECT * FROM HNet_ConnectionProperties')
        $searcher = New-Object System.Management.ManagementObjectSearcher($scope, $query)
        foreach ($entry in $searcher.Get()) {
            if ([bool] $entry['IsIcsPrivate'] -or [bool] $entry['IsIcsPublic']) {
                $entry['IsIcsPrivate'] = $false
                $entry['IsIcsPublic'] = $false
                $entry.Put() | Out-Null
            }
        }
    } catch { Write-Warning "Could not clear stale ICS WMI state: $($_.Exception.Message)" }

    $sharedAccessKey = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\SharedAccess'
    Set-ItemProperty -Path $sharedAccessKey -Name PrivateIndex -Value ([uint32]::MaxValue) -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $sharedAccessKey -Name PublicIndex -Value ([uint32]::MaxValue) -ErrorAction SilentlyContinue
}

$manager = New-Object -ComObject HNetCfg.HNetShare
$connections = @($manager.EnumEveryConnection())
if ($Disable) {
    foreach ($connection in $connections) {
        $sharing = $manager.INetSharingConfigurationForINetConnection.Invoke($connection)
        if ($sharing.SharingEnabled) { $sharing.DisableSharing() }
    }
    Clear-StaleIcsState
    Write-Host 'Internet Connection Sharing disabled for tunnel restart'
    exit 0
}

$privateName = [string] $config.Routing.PrivateInterface
$deadline = (Get-Date).AddSeconds(60)
while (-not (Get-NetAdapter -Name $privateName -ErrorAction SilentlyContinue)) {
    if ((Get-Date) -ge $deadline) { throw "The $privateName adapter did not appear." }
    Start-Sleep -Seconds 2
}
Start-Sleep -Seconds 2

Clear-StaleIcsState
$sharingService = Get-Service -Name SharedAccess -ErrorAction Stop
if ($sharingService.Status -eq 'Running') { Restart-Service -Name SharedAccess -Force -ErrorAction Stop }
else { Start-Service -Name SharedAccess -ErrorAction Stop }
Start-Sleep -Seconds 4

$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
    Where-Object { $_.NextHop -ne '0.0.0.0' } |
    Sort-Object RouteMetric, InterfaceMetric |
    Select-Object -First 1
if (-not $defaultRoute) { throw 'No internet-facing default route was found.' }
$publicName = [string] $defaultRoute.InterfaceAlias

$manager = New-Object -ComObject HNetCfg.HNetShare
$connections = @($manager.EnumEveryConnection())
function Get-SharingConnection([string] $Name) {
    foreach ($connection in $connections) {
        $properties = $manager.NetConnectionProps.Invoke($connection)
        if ($properties.Name -eq $Name) {
            return [pscustomobject]@{
                Connection = $connection
                Configuration = $manager.INetSharingConfigurationForINetConnection.Invoke($connection)
            }
        }
    }
    throw "The Windows network connection '$Name' was not found by Internet Connection Sharing."
}

$public = Get-SharingConnection $publicName
$private = Get-SharingConnection $privateName

foreach ($connection in $connections) {
    $sharing = $manager.INetSharingConfigurationForINetConnection.Invoke($connection)
    if ($sharing.SharingEnabled) {
        $properties = $manager.NetConnectionProps.Invoke($connection)
        if ($properties.Name -notin @($publicName, $privateName)) { $sharing.DisableSharing() }
    }
}
if (-not $public.Configuration.SharingEnabled -or $public.Configuration.SharingConnectionType -ne 0) {
    if ($public.Configuration.SharingEnabled) { $public.Configuration.DisableSharing() }
    try { $public.Configuration.EnableSharing(0) }
    catch { throw "Could not enable public sharing on '$publicName': $($_.Exception.Message)" }
}
if (-not $private.Configuration.SharingEnabled -or $private.Configuration.SharingConnectionType -ne 1) {
    if ($private.Configuration.SharingEnabled) { $private.Configuration.DisableSharing() }
    try { $private.Configuration.EnableSharing(1) }
    catch { throw "Could not enable private sharing on '$privateName': $($_.Exception.Message)" }
}

Set-Service -Name SharedAccess -StartupType Automatic
New-Item -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\SharedAccess' -Force | Out-Null
New-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\SharedAccess' -Name EnableRebootPersistConnection -PropertyType DWord -Value 1 -Force | Out-Null
Get-NetIPInterface -AddressFamily IPv4 | Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue

Write-Host "Internet Connection Sharing: $publicName -> $privateName" -ForegroundColor Green
