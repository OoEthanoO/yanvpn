[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string] $Endpoint,
    [string] $RealitySni = 'www.apple.com',
    [ValidateSet('Auto','Reality','CaddyWebSocket','Dual')][string] $FallbackMode = 'Auto',
    [string] $Caddyfile,
    [switch] $SkipDownloads
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Administrator
Initialize-StateDirectory

function Install-WireGuard {
    if (Test-Path -LiteralPath $script:WireGuardExe) { Write-Ok 'WireGuard is installed'; return }
    if ($SkipDownloads) { throw 'WireGuard is missing and -SkipDownloads was specified.' }
    Write-Step 'Installing official WireGuard for Windows'
    $msi = Join-Path $env:TEMP 'wireguard-amd64-1.1.msi'
    Invoke-WebRequest -UseBasicParsing -Uri 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.msi' -OutFile $msi
    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', 'DO_NOT_LAUNCH=1') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "WireGuard MSI failed with exit code $($p.ExitCode)." }
    if (-not (Test-Path -LiteralPath $script:WireGuardExe)) { throw 'WireGuard installed but wireguard.exe was not found.' }
    Write-Ok 'WireGuard installed'
}

function Install-AmneziaWG {
    if (Test-Path -LiteralPath $script:AmneziaExe) { Write-Ok 'AmneziaWG is installed'; return }
    if ($SkipDownloads) { throw 'AmneziaWG is missing and -SkipDownloads was specified.' }
    Write-Step 'Installing official AmneziaWG for Windows'
    $release = Invoke-RestMethod -Headers @{ 'User-Agent' = 'yanvpn' } -Uri 'https://api.github.com/repos/amnezia-vpn/amneziawg-windows-client/releases/latest'
    $asset = $release.assets | Where-Object { $_.name -match 'amd64.*\.msi$|x64.*\.msi$' } | Select-Object -First 1
    if (-not $asset) { throw 'The latest AmneziaWG release has no amd64 MSI.' }
    $msi = Join-Path $env:TEMP $asset.name
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $msi
    $p = Start-Process msiexec.exe -ArgumentList @('/i', $msi, '/qn', 'DO_NOT_LAUNCH=1') -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw "AmneziaWG MSI failed with exit code $($p.ExitCode)." }
    if (-not (Test-Path -LiteralPath $script:AmneziaExe)) { throw 'AmneziaWG installed but amneziawg.exe was not found.' }
    Write-Ok 'AmneziaWG installed'
}

function Install-SingBox {
    if (Test-Path -LiteralPath $script:SingBoxExe) {
        $version = ((& $script:SingBoxExe version | Select-Object -First 1) -split '\s+')[-1]
        Write-Ok "sing-box $version is installed"
        return $version
    }
    if ($SkipDownloads) { throw 'sing-box is missing and -SkipDownloads was specified.' }
    Write-Step 'Installing native sing-box for Windows'
    $release = Invoke-RestMethod -Headers @{ 'User-Agent' = 'yanvpn' } -Uri 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
    $version = $release.tag_name.TrimStart('v')
    $asset = $release.assets | Where-Object { $_.name -eq "sing-box-$version-windows-amd64.zip" } | Select-Object -First 1
    if (-not $asset) { throw "sing-box $version has no windows-amd64 release asset." }
    $zip = Join-Path $env:TEMP $asset.name
    $unpack = Join-Path $env:TEMP "yanvpn-sing-box-$version"
    Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $zip
    if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
    Expand-Archive -LiteralPath $zip -DestinationPath $unpack
    $source = Get-ChildItem -LiteralPath $unpack -Filter sing-box.exe -Recurse | Select-Object -First 1
    if (-not $source) { throw 'Downloaded sing-box archive did not contain sing-box.exe.' }
    Copy-Item -LiteralPath $source.FullName -Destination $script:SingBoxExe -Force
    Write-Ok "sing-box $version installed"
    return $version
}

Install-WireGuard
Install-AmneziaWG
$singBoxVersion = Install-SingBox

if (Test-Path -LiteralPath $script:YanVpnConfigPath) {
    throw "$($script:YanVpnConfigPath) already exists. Use vpnctl.ps1 to manage the existing installation."
}

Write-Step 'Generating server identities'
$wgPrivate = New-WgPrivateKey
$awgPrivate = New-WgPrivateKey
$realityPair = & $script:SingBoxExe generate reality-keypair
$realityPrivate = (($realityPair | Where-Object { $_ -match '^PrivateKey:' }) -split ':\s*', 2)[1].Trim()
$realityPublic = (($realityPair | Where-Object { $_ -match '^PublicKey:' }) -split ':\s*', 2)[1].Trim()
if (-not $realityPrivate -or -not $realityPublic) { throw 'Could not parse the REALITY keypair.' }
$shortIdBytes = [byte[]]::new(8)
[Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($shortIdBytes)
$shortId = -join ($shortIdBytes | ForEach-Object { $_.ToString('x2') })
$fallbackPath = '/vpn-' + (-join ($shortIdBytes | ForEach-Object { $_.ToString('x2') }))
$fallbackInternalPort = 10080

$tcp443 = Get-NetTCPConnection -State Listen -LocalPort 443 -ErrorAction SilentlyContinue | Select-Object -First 1
if ($FallbackMode -eq 'Auto') {
    if (-not $tcp443) {
        $FallbackMode = 'Reality'
    } else {
        $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$($tcp443.OwningProcess)"
        if ($owner.Name -ne 'caddy.exe') {
            throw "TCP 443 is already owned by $($owner.Name). Use -FallbackMode CaddyWebSocket only with Caddy, or free the port."
        }
        $FallbackMode = 'Dual'
        if (-not $Caddyfile -and $owner.CommandLine -match '--config\s+"([^"]+)"') { $Caddyfile = $Matches[1] }
    }
}
if ($FallbackMode -in @('CaddyWebSocket','Dual') -and (-not $Caddyfile -or -not (Test-Path -LiteralPath $Caddyfile))) {
    throw 'CaddyWebSocket or Dual mode needs -Caddyfile pointing to the active Caddyfile.'
}
$random = [Security.Cryptography.RandomNumberGenerator]::Create()
function Get-RandomInt([int] $Min, [int] $Max) {
    $bytes = [byte[]]::new(4); $random.GetBytes($bytes)
    $raw = [BitConverter]::ToUInt32($bytes, 0)
    $Min + [int] ($raw % [uint32] ($Max - $Min + 1))
}
$headers = [Collections.Generic.HashSet[uint32]]::new()
while ($headers.Count -lt 4) { [void] $headers.Add([uint32](Get-RandomInt 5 2147483646)) }
$h = @($headers)

$s1 = Get-RandomInt 15 150
$s2 = Get-RandomInt 15 150
while ($s1 + 56 -eq $s2) { $s2 = Get-RandomInt 15 150 }

$hasWinNat = $false
try {
    $null = Get-CimClass -Namespace Root/StandardCimv2 -ClassName MSFT_NetNat -ErrorAction Stop
    $hasWinNat = $true
} catch {}
$routingMode = if ($hasWinNat) { 'WinNat' } else { 'Ics' }
$wireGuardEnabled = $hasWinNat
$awgSubnet = if ($hasWinNat) { '10.66.67' } else { '192.168.137' }

$config = [ordered]@{
    SchemaVersion = 1
    Endpoint = $Endpoint
    ClientMtu = 1380
    Routing = [ordered]@{ Mode = $routingMode; PrivateInterface = $script:AmneziaTunnel }
    WireGuard = [ordered]@{ Enabled = $wireGuardEnabled; Port = 51820; Subnet = '10.66.66'; PrivateKey = $wgPrivate; PublicKey = Get-WgPublicKey $wgPrivate }
    AmneziaWG = [ordered]@{
        Enabled = $true; Port = 443; Subnet = $awgSubnet; PrivateKey = $awgPrivate; PublicKey = Get-WgPublicKey $awgPrivate
        Jc = Get-RandomInt 4 12; Jmin = 50; Jmax = 1000; S1 = $s1; S2 = $s2
        H1 = $h[0]; H2 = $h[1]; H3 = $h[2]; H4 = $h[3]
    }
    Reality = [ordered]@{
        Mode = $FallbackMode; Port = if ($FallbackMode -eq 'Dual') { 8443 } else { 443 }; WebSocketPort = 443
        InternalPort = $fallbackInternalPort; Path = $fallbackPath
        Sni = $RealitySni; PrivateKey = $realityPrivate; PublicKey = $realityPublic
        ShortId = $shortId; SingBoxVersion = $singBoxVersion; Caddyfile = $Caddyfile
    }
}

if ($FallbackMode -in @('CaddyWebSocket','Dual')) {
    Write-Step 'Adding the VPN WebSocket route to the existing Caddy site'
    $caddyText = Get-Content -Raw -LiteralPath $Caddyfile
    $markerStart = '# BEGIN yanvpn (managed)'
    $markerEnd = '# END yanvpn (managed)'
    $protocolMarkerStart = '# BEGIN yanvpn protocols (managed)'
    $protocolMarkerEnd = '# END yanvpn protocols (managed)'
    $snippet = @"
	$markerStart
	@yanvpn path $fallbackPath
	reverse_proxy @yanvpn 127.0.0.1:$fallbackInternalPort
	$markerEnd

"@
    if ($caddyText -match '(?s)# BEGIN yanvpn \(managed\).*?# END yanvpn \(managed\)\r?\n?') {
        $markerRegex = [regex]::new('(?s)[ \t]*# BEGIN yanvpn \(managed\).*?# END yanvpn \(managed\)\r?\n?')
        $caddyText = $markerRegex.Replace($caddyText, $snippet, 1)
    } elseif ($caddyText -match '(?m)^\s*reverse_proxy\s+') {
        $proxyRegex = [regex]::new('(?m)^(\s*reverse_proxy\s+)')
        $caddyText = $proxyRegex.Replace($caddyText, ($snippet + '$1'), 1)
    } else {
        throw 'Could not find a reverse_proxy directive in the Caddyfile; refusing to guess where to add the VPN route.'
    }
    if ($caddyText -notmatch [regex]::Escape($protocolMarkerStart)) {
        $globalOptions = [regex]::new('(?ms)^\{\r?\n(.*?)^\}')
        if (-not $globalOptions.IsMatch($caddyText)) {
            throw 'Could not find Caddy global options; refusing to guess where to disable HTTP/3.'
        }
        $caddyText = $globalOptions.Replace($caddyText, {
            param($match)
            '{' + "`r`n" + $match.Groups[1].Value + "`r`n`t$protocolMarkerStart`r`n`tservers {`r`n`t`tprotocols h1 h2`r`n`t}`r`n`t$protocolMarkerEnd`r`n}"
        }, 1)
    }
    $backup = "$Caddyfile.yanvpn-backup-$(Get-Date -Format yyyyMMddHHmmss)"
    Copy-Item -LiteralPath $Caddyfile -Destination $backup
    [IO.File]::WriteAllText($Caddyfile, $caddyText, [Text.UTF8Encoding]::new($false))
    $caddyExe = (Get-CimInstance Win32_Process -Filter "ProcessId=$($tcp443.OwningProcess)").ExecutablePath
    & $caddyExe validate --config $Caddyfile
    if ($LASTEXITCODE -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $Caddyfile -Force
        throw 'Caddy rejected the VPN route; the original Caddyfile was restored.'
    }
    & $caddyExe reload --config $Caddyfile
    if ($LASTEXITCODE -ne 0) {
        Copy-Item -LiteralPath $backup -Destination $Caddyfile -Force
        & $caddyExe reload --config $Caddyfile | Out-Null
        throw 'Caddy reload failed; the original Caddyfile was restored and reloaded.'
    }
    Write-Ok "Caddy routes $fallbackPath to native sing-box"
}

Write-YanVpnJson $script:YanVpnConfigPath $config

Write-Step 'Configuring Windows firewall'
foreach ($rule in @(
    @{ Name = 'yanvpn-wireguard'; Protocol = 'UDP'; Port = 51820 },
    @{ Name = 'yanvpn-amneziawg'; Protocol = 'UDP'; Port = 443 },
    @{ Name = 'yanvpn-reality'; Protocol = 'TCP'; Port = if ($FallbackMode -eq 'Dual') { 8443 } else { 443 } }
)) {
    Remove-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $rule.Name -DisplayName $rule.Name -Direction Inbound -Action Allow -Protocol $rule.Protocol -LocalPort $rule.Port | Out-Null
}

Write-Step 'Starting all server transports'
Update-ServerRuntime
Get-NetIPInterface -AddressFamily IPv4 | Set-NetIPInterface -Forwarding Enabled -ErrorAction SilentlyContinue

Write-Step "Configuring Windows routing with $routingMode"
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
    $routingAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$routingTarget`""
    $routingTrigger = New-ScheduledTaskTrigger -AtStartup
    $routingSettings = New-ScheduledTaskSettingsSet -RestartCount 10 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 3)
    Register-ScheduledTask -TaskName $routingTask -Action $routingAction -Trigger $routingTrigger -Settings $routingSettings -User 'SYSTEM' -RunLevel Highest -ErrorAction Stop | Out-Null
    Write-Warn 'This Windows edition has no WinNAT provider; AmneziaWG uses native Internet Connection Sharing and plain WireGuard is disabled.'
}

$vpnctlTarget = Join-Path $script:YanVpnRoot 'vpnctl.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'vpnctl.ps1') -Destination $vpnctlTarget -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'common.ps1') -Destination (Join-Path $script:YanVpnRoot 'common.ps1') -Force

Write-Host ''
Write-Host 'yanvpn Windows server is installed.' -ForegroundColor Green
Write-Host "  Endpoint:   $Endpoint"
if ($wireGuardEnabled) { Write-Host '  WireGuard:  UDP 51820' }
else { Write-Host '  WireGuard:  disabled (WinNAT is unavailable on this Windows edition)' }
Write-Host '  AmneziaWG:  UDP 443'
if ($FallbackMode -eq 'Dual') {
    Write-Host '  HTTPS:      VLESS WebSocket through Caddy TCP 443'
    Write-Host '  REALITY:    VLESS + REALITY TCP 8443'
} elseif ($FallbackMode -eq 'CaddyWebSocket') { Write-Host '  HTTPS:      VLESS WebSocket through Caddy TCP 443' }
else { Write-Host '  REALITY:    TCP 443' }
Write-Host ''
# Spelled out with -ExecutionPolicy Bypass: if this installer was itself started
# that way, the user's window still refuses scripts, and a bare `& vpnctl.ps1`
# fails there with "running scripts is disabled on this system".
Write-Host "Create the clients next:"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File '$vpnctlTarget' add phone"
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File '$vpnctlTarget' add laptop"
