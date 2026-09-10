Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot '..\server\windows\common.ps1')

$testRoot = Join-Path $env:TEMP ("yanvpn-test-" + [Guid]::NewGuid().ToString('N'))
try {
    $script:YanVpnRoot = $testRoot
    $script:YanVpnConfigPath = Join-Path $testRoot 'config.json'
    $script:YanVpnClientsPath = Join-Path $testRoot 'clients'
    New-Item -ItemType Directory -Force -Path (Join-Path $script:YanVpnClientsPath 'phone') | Out-Null

    $client = [ordered]@{
        Name = 'phone'; Host = 2
        WireGuard = [ordered]@{ PrivateKey = 'wg-private'; PublicKey = 'wg-public'; PresharedKey = 'wg-psk' }
        AmneziaWG = [ordered]@{ PrivateKey = 'awg-private'; PublicKey = 'awg-public'; PresharedKey = 'awg-psk' }
        RealityUuid = '11111111-1111-1111-1111-111111111111'
    }
    $config = [ordered]@{
        SchemaVersion = 1; Endpoint = 'vpn.example.test'; ClientMtu = 1380
        WireGuard = [ordered]@{ Enabled = $true; Port = 51820; Subnet = '10.66.66'; PrivateKey = 'server-wg-private'; PublicKey = 'server-wg-public' }
        AmneziaWG = [ordered]@{
            Enabled = $true; Port = 443; Subnet = '10.66.67'; PrivateKey = 'server-awg-private'; PublicKey = 'server-awg-public'
            Jc = 7; Jmin = 50; Jmax = 1000; S1 = 40; S2 = 120; H1 = 1; H2 = 2; H3 = 3; H4 = 4
        }
        Reality = [ordered]@{
            Mode = 'Reality'; Port = 443; InternalPort = 10080; Path = '/vpn-test'
            Sni = 'www.apple.com'; PrivateKey = 'reality-private'; PublicKey = 'reality-public'
            ShortId = '0102030405060708'; SingBoxVersion = '1.13.0'
        }
    }

    Write-YanVpnJson $script:YanVpnConfigPath $config
    Write-YanVpnJson (Join-Path $script:YanVpnClientsPath 'phone\meta.json') $client
    $loadedConfig = Read-YanVpnConfig
    $loadedClient = @(Get-ClientRecords)[0]
    Write-ClientFiles $loadedConfig $loadedClient

    $wgClient = Get-Content -Raw -LiteralPath (Join-Path $script:YanVpnClientsPath 'phone\wg.conf')
    $awgClient = Get-Content -Raw -LiteralPath (Join-Path $script:YanVpnClientsPath 'phone\awg.conf')
    $realityUrl = Get-Content -Raw -LiteralPath (Join-Path $script:YanVpnClientsPath 'phone\reality.url')
    $realityJson = Get-Content -Raw -LiteralPath (Join-Path $script:YanVpnClientsPath 'phone\reality.json') | ConvertFrom-Json
    $transports = Get-Content -Raw -LiteralPath (Join-Path $script:YanVpnClientsPath 'phone\transports.json') | ConvertFrom-Json
    $wgServer = Get-WireGuardServerConfig $loadedConfig
    $awgServer = Get-AmneziaServerConfig $loadedConfig
    $realityServer = Get-RealityServerConfig $loadedConfig

    $checks = [ordered]@{
        'WireGuard client endpoint' = $wgClient.Contains('Endpoint = vpn.example.test:51820')
        'WireGuard client address' = $wgClient.Contains('Address = 10.66.66.2/32')
        'WireGuard server peer' = $wgServer.Contains('PublicKey = wg-public')
        'Amnezia client endpoint' = $awgClient.Contains('Endpoint = vpn.example.test:443')
        'Amnezia obfuscation' = $awgClient.Contains('Jc = 7') -and $awgServer.Contains('H4 = 4')
        'REALITY URL' = $realityUrl.Contains('vless://11111111-1111-1111-1111-111111111111@vpn.example.test:443')
        'REALITY client TUN' = $realityJson.inbounds[0].type -eq 'tun' -and $realityJson.route.final -eq 'proxy'
        'REALITY server user' = $realityServer.inbounds[0].users[0].uuid -eq $client.RealityUuid
        'Transport manifest' = $transports.WireGuard -and $transports.AmneziaWG -and $transports.Reality
        'IPv6 leak prevention' = $wgClient.Contains('0.0.0.0/0, ::/0') -and $awgClient.Contains('0.0.0.0/0, ::/0')
    }

    $failed = @($checks.GetEnumerator() | Where-Object { -not $_.Value })
    foreach ($check in $checks.GetEnumerator()) {
        if ($check.Value) { Write-Host "PASS $($check.Key)" -ForegroundColor Green }
        else { Write-Host "FAIL $($check.Key)" -ForegroundColor Red }
    }
    if ($failed.Count) { throw "$($failed.Count) Windows generator test(s) failed." }

    $loadedConfig.Reality.Mode = 'Dual'
    $loadedConfig.Reality.Port = 8443
    $dualServer = Get-RealityServerConfig $loadedConfig
    $dualClient = Get-RealityClientConfig $loadedConfig $loadedClient
    if ($dualServer.inbounds.Count -ne 2 -or $dualServer.inbounds[1].listen_port -ne 8443) {
        throw 'Dual fallback did not generate both WebSocket and REALITY inbounds.'
    }
    if ($dualServer.inbounds[0].users[0].PSObject.Properties.Name -contains 'flow') {
        throw 'WebSocket users must not enable XTLS Vision flow.'
    }
    if ($dualClient.outbounds[0].server_port -ne 8443 -or -not $dualClient.outbounds[0].tls.reality.enabled) {
        throw 'Dual client did not select VLESS + REALITY on TCP 8443.'
    }
    $tags = @($dualServer.inbounds | ForEach-Object { $_.tag })
    $uniqueTags = @($tags | Select-Object -Unique)
    if ($uniqueTags.Count -ne $tags.Count) {
        throw 'Dual inbounds reuse a tag; sing-box rejects duplicate inbound tags.'
    }
    Write-Host 'PASS Dual HTTPS + REALITY generation' -ForegroundColor Green
    Write-Host 'All Windows generator tests passed.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
