[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Write-Host 'yanvpn Windows preflight' -ForegroundColor Cyan

$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
    Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
$address = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $route.InterfaceIndex |
    Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1
$public = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 8).Trim()

Write-Host "  Server LAN address: $($address.IPAddress)"
Write-Host "  Default interface:  $($route.InterfaceAlias)"
Write-Host "  Public address:     $public"

if ($address.IPAddress -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)') {
    Write-Host ''
    Write-Host "Reserve $($address.IPAddress) in the router, then forward:" -ForegroundColor Yellow
    Write-Host '  UDP 443   -> this server (AmneziaWG)'
    Write-Host '  TCP 443   -> this server (REALITY)'
    Write-Host '  UDP 51820 -> this server (plain WireGuard, optional outside home)'
    Write-Host ''
    Write-Host "Router: http://$($route.NextHop)"
}

if ($public -match '^(100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.|10\.|192\.168\.)') {
    Write-Warning 'The reported public address is private/CGNAT. Direct inbound VPN connections will not work until the ISP provides a public address.'
}
