[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('add','remove','list','show','qr','status','endpoint','regen','backup')][string] $Command = 'status',
    [Parameter(Position = 1)][string] $Name,
    [Parameter(Position = 2)][ValidateSet('wg','awg','reality','all')][string] $Transport = 'all',
    [string] $OutputPath
)

. (Join-Path $PSScriptRoot 'common.ps1')
Assert-Administrator
$config = Read-YanVpnConfig

function Get-Client([string] $ClientName) {
    if (-not $ClientName) { throw 'A client name is required.' }
    $path = Join-Path (Join-Path $script:YanVpnClientsPath $ClientName) 'meta.json'
    if (-not (Test-Path -LiteralPath $path)) { throw "No such client: $ClientName" }
    Get-Content -Raw -LiteralPath $path | ConvertFrom-Json
}

function Ensure-QrCoder {
    $dll = Join-Path $script:YanVpnBinPath 'QRCoder.dll'
    if (-not (Test-Path -LiteralPath $dll)) {
        Write-Step 'Downloading QRCoder locally to render private QR codes'
        $version = '1.8.0'
        $zip = Join-Path $env:TEMP "qrcoder-$version.zip"
        $unpack = Join-Path $env:TEMP "yanvpn-qrcoder-$version"
        Invoke-WebRequest -UseBasicParsing -Uri "https://www.nuget.org/api/v2/package/QRCoder/$version" -OutFile $zip
        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack
        $source = Get-ChildItem -LiteralPath $unpack -Filter QRCoder.dll -Recurse |
            Where-Object { $_.FullName -match 'lib\\net(35|4)' } | Select-Object -First 1
        if (-not $source) { throw 'Downloaded QRCoder package did not contain a .NET Framework build.' }
        Copy-Item -LiteralPath $source.FullName -Destination $dll -Force
    }
    if (-not ('QRCoder.QRCodeGenerator' -as [type])) { Add-Type -Path $dll }
}

function New-ClientQr([object] $Client, [string] $Kind) {
    Ensure-QrCoder
    $dir = Join-Path $script:YanVpnClientsPath $Client.Name
    switch ($Kind) {
        'wg' { $sourcePath = Join-Path $dir 'wg.conf'; $label = 'WireGuard' }
        'awg' { $sourcePath = Join-Path $dir 'awg.conf'; $label = 'AmneziaWG' }
        'reality' { $sourcePath = Join-Path $dir 'reality.url'; $label = 'REALITY' }
    }
    $payload = (Get-Content -Raw -LiteralPath $sourcePath).TrimEnd("`r", "`n")
    $output = Join-Path $dir "$Kind-qr.png"
    $generator = [QRCoder.QRCodeGenerator]::new()
    $data = $generator.CreateQrCode($payload, [QRCoder.QRCodeGenerator+ECCLevel]::M)
    $qr = [QRCoder.PngByteQRCode]::new($data)
    [IO.File]::WriteAllBytes($output, $qr.GetGraphic(10))
    $qr.Dispose()
    $data.Dispose()
    $generator.Dispose()
    Write-Ok "$label QR: $output"
}

switch ($Command) {
    'add' {
        if (-not $Name -or $Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,30}$') {
            throw 'Usage: vpnctl.ps1 add <name> (letters, digits, dash, underscore; max 31)'
        }
        $dir = Join-Path $script:YanVpnClientsPath $Name
        if (Test-Path -LiteralPath $dir) { throw "Client '$Name' already exists." }
        New-Item -ItemType Directory -Path $dir | Out-Null
        $wgPrivate = New-WgPrivateKey
        $awgPrivate = New-WgPrivateKey
        $client = [ordered]@{
            Name = $Name
            Host = Get-NextClientHost
            WireGuard = [ordered]@{
                PrivateKey = $wgPrivate; PublicKey = Get-WgPublicKey $wgPrivate; PresharedKey = New-WgPresharedKey
            }
            AmneziaWG = [ordered]@{
                PrivateKey = $awgPrivate; PublicKey = Get-WgPublicKey $awgPrivate; PresharedKey = New-WgPresharedKey
            }
            RealityUuid = [Guid]::NewGuid().ToString()
        }
        Write-YanVpnJson (Join-Path $dir 'meta.json') $client
        $client = Get-Client $Name
        Write-ClientFiles $config $client
        Update-ServerRuntime
        Write-Ok "Created '$Name' with tunnel host .$($client.Host)"
        foreach ($kind in 'wg','awg','reality') { New-ClientQr $client $kind }
        Write-Host "Copy this entire directory to the device installer: $dir"
    }
    'remove' {
        [void] (Get-Client $Name)
        $dir = Join-Path $script:YanVpnClientsPath $Name
        Remove-Item -LiteralPath $dir -Recurse -Force
        Update-ServerRuntime
        Write-Ok "Revoked '$Name' on all transports and removed its key directory."
    }
    'list' {
        Get-ClientRecords | Select-Object Name, Host, RealityUuid | Format-Table -AutoSize
    }
    'show' {
        $client = Get-Client $Name
        $dir = Join-Path $script:YanVpnClientsPath $client.Name
        switch ($Transport) {
            'wg' { Get-Content -Raw -LiteralPath (Join-Path $dir 'wg.conf') }
            'awg' { Get-Content -Raw -LiteralPath (Join-Path $dir 'awg.conf') }
            'reality' { Get-Content -Raw -LiteralPath (Join-Path $dir 'reality.url') }
            default { throw 'Choose one transport for show: wg, awg, or reality.' }
        }
    }
    'qr' {
        $client = Get-Client $Name
        $kinds = if ($Transport -eq 'all') { @('wg','awg','reality') } else { @($Transport) }
        foreach ($kind in $kinds) { New-ClientQr $client $kind }
    }
    'status' {
        $wgService = Get-Service -Name "WireGuardTunnel`$$($script:WireGuardTunnel)" -ErrorAction SilentlyContinue
        $awgService = Get-Service -Name "AmneziaWGTunnel`$$($script:AmneziaTunnel)" -ErrorAction SilentlyContinue
        $task = Get-ScheduledTask -TaskName $script:RealityTask -ErrorAction SilentlyContinue
        $fallbackName = switch ($config.Reality.Mode) {
            'CaddyWebSocket' { 'HTTPS/VLESS' }
            'Dual' { 'HTTPS/VLESS + REALITY' }
            default { 'REALITY' }
        }
        $fallbackListening = if ($config.Reality.Mode -eq 'Dual') { "TCP 443/$($config.Reality.Port)" } else { "TCP $($config.Reality.Port)" }
        $rows = @(
            [pscustomobject]@{ Transport = 'WireGuard'; State = if ($wgService) { $wgService.Status } else { 'Absent' }; Listening = 'UDP 51820' }
            [pscustomobject]@{ Transport = 'AmneziaWG'; State = if ($awgService) { $awgService.Status } else { 'Absent' }; Listening = 'UDP 443' }
            [pscustomobject]@{ Transport = $fallbackName; State = if ($task) { $task.State } else { 'Absent' }; Listening = $fallbackListening }
        )
        $rows | Format-Table -AutoSize
        Write-Host "Endpoint: $($config.Endpoint)"
        Write-Host "Clients:  $(@(Get-ClientRecords).Count)"
    }
    'endpoint' {
        if (-not $Name) { throw 'Usage: vpnctl.ps1 endpoint <hostname-or-ip>' }
        $config.Endpoint = $Name
        Write-YanVpnJson $script:YanVpnConfigPath $config
        foreach ($client in Get-ClientRecords) { Write-ClientFiles $config $client }
        Write-Ok "Endpoint changed to $Name. Reinstall or re-import each client profile."
    }
    'regen' {
        foreach ($client in Get-ClientRecords) { Write-ClientFiles $config $client }
        Update-ServerRuntime
        Write-Ok 'Regenerated server and client configs from the registry.'
    }
    'backup' {
        if (-not $OutputPath) {
            $OutputPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "yanvpn-backup-$(Get-Date -Format yyyyMMdd).zip"
        }
        Compress-Archive -LiteralPath $script:YanVpnRoot -DestinationPath $OutputPath -CompressionLevel Optimal -Force
        Write-Ok "Private-key backup written to $OutputPath"
    }
}
