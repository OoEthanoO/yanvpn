[CmdletBinding()]
param([string] $SettingsPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $SettingsPath) { $SettingsPath = Join-Path $PSScriptRoot 'vercel-ddns.json' }
$statusPath = Join-Path (Split-Path -Parent $SettingsPath) 'vercel-ddns-status.json'
$utf8 = [Text.UTF8Encoding]::new($false)

function Save-Status([object] $Value) {
    [IO.File]::WriteAllText($statusPath, ($Value | ConvertTo-Json -Depth 5), $utf8)
}

function Test-PublicIPv4([string] $Value) {
    $parsed = $null
    if ($Value -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($Value, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $b = $parsed.GetAddressBytes()
    return -not ($b[0] -in 0,10,127 -or $b[0] -ge 224 -or
        ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) -or
        ($b[0] -eq 169 -and $b[1] -eq 254) -or
        ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) -or
        ($b[0] -eq 192 -and $b[1] -eq 168))
}

function Invoke-DnsApi([string] $Method, [string] $Path, [object] $Body = $null) {
    $request = @{
        Uri = 'https://api.vercel.com' + $Path
        Method = $Method; Headers = $script:dnsHeaders; TimeoutSec = 25; ErrorAction = 'Stop'
    }
    if ($null -ne $Body) {
        $request.Body = $Body | ConvertTo-Json -Compress
        $request.ContentType = 'application/json'
    }
    try { Invoke-RestMethod @request }
    catch {
        $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 'network error' }
        # Never include request headers or bearer credentials in task logs.
        throw "Vercel DNS API $Method failed ($code). Check token expiry and team access."
    }
}

function Find-ManagedRecord([object] $Settings, [string] $ScopeQuery, [switch] $AnyId) {
    $found = @()
    $cursor = $null
    $seen = @{}
    do {
        $path = '/v5/domains/{0}/records?limit=100&{1}' -f [Uri]::EscapeDataString($Settings.Domain), $ScopeQuery
        if ($null -ne $cursor) { $path += '&until=' + [Uri]::EscapeDataString([string]$cursor) }
        $page = Invoke-DnsApi 'GET' $path
        $found += @($page.records | Where-Object { $_.name -eq $Settings.Subdomain })
        $cursor = if ($page.PSObject.Properties.Name -contains 'pagination' -and $null -ne $page.pagination -and $page.pagination.PSObject.Properties.Name -contains 'next') {
            $page.pagination.next
        } else { $null }
        if ($null -ne $cursor) {
            if ($seen.ContainsKey([string]$cursor)) { throw 'Vercel DNS pagination did not advance.' }
            $seen[[string]$cursor] = $true
        }
    } while ($null -ne $cursor)
    if ($found.Count -ne 1 -or $found[0].type -ne 'A') {
        throw 'Expected exactly one existing A record at the configured subdomain. DNS was not changed.'
    }
    if (-not $AnyId -and $found[0].id -ne $Settings.RecordId) {
        throw 'The managed DNS record ID changed. Review and reinstall the updater.'
    }
    return $found[0]
}

try {
    $settings = Get-Content -Raw -LiteralPath $SettingsPath | ConvertFrom-Json
    Add-Type -AssemblyName System.Security
    $cipher = [Convert]::FromBase64String([IO.File]::ReadAllText($settings.TokenPath))
    $plain = [Security.Cryptography.ProtectedData]::Unprotect($cipher, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    $script:dnsHeaders = @{ Authorization = 'Bearer ' + [Text.Encoding]::UTF8.GetString($plain) }
    [Array]::Clear($plain, 0, $plain.Length)

    $addresses = @()
    foreach ($service in 'https://api.ipify.org','https://checkip.amazonaws.com','https://ipv4.icanhazip.com') {
        try {
            $candidate = (Invoke-RestMethod -Uri $service -TimeoutSec 10).ToString().Trim()
            if (Test-PublicIPv4 $candidate) { $addresses += $candidate }
        } catch { }
        if ($addresses.Count -ge 2) { break }
    }
    if ($addresses.Count -lt 2 -or $addresses[0] -ne $addresses[1]) {
        throw 'Could not confirm the same public IPv4 address with two independent services. DNS was not changed.'
    }
    $publicIp = $addresses[0]
    $scopeQuery = 'slug=' + [Uri]::EscapeDataString($settings.TeamSlug)
    $record = Find-ManagedRecord $settings $scopeQuery
    $changed = $record.value -ne $publicIp
    if ($changed) {
        $path = '/v1/domains/records/{0}?{1}' -f [Uri]::EscapeDataString($record.id), $scopeQuery
        $null = Invoke-DnsApi 'PATCH' $path @{ value = $publicIp }
        # Vercel gives a record a new ID whenever it is edited, so find our record by name after our
        # own update and remember the new ID. The ID check above still catches outside changes.
        $verified = Find-ManagedRecord $settings $scopeQuery -AnyId
        if ($verified.value -ne $publicIp) { throw 'Vercel did not return the expected address after the update.' }
        if ($verified.id -ne $settings.RecordId) {
            $settings.RecordId = $verified.id
            [IO.File]::WriteAllText($SettingsPath, ($settings | ConvertTo-Json), $utf8)
        }
    }
    Save-Status ([ordered]@{
        CheckedAt = [DateTime]::UtcNow.ToString('o'); Success = $true
        Hostname = $settings.Subdomain + '.' + $settings.Domain
        PublicIPv4 = $publicIp; Changed = $changed; TokenExpires = $settings.TokenExpires
    })
    Write-Output ('DNS check succeeded: {0}.{1} -> {2}; changed={3}' -f $settings.Subdomain,$settings.Domain,$publicIp,$changed)
} catch {
    Save-Status ([ordered]@{ CheckedAt = [DateTime]::UtcNow.ToString('o'); Success = $false; Error = $_.Exception.Message })
    throw
} finally {
    $script:dnsHeaders = $null
    if (Get-Variable plain -ErrorAction SilentlyContinue) { $plain = $null }
}
