[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9.-]+$')][string] $Domain,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string] $Subdomain,
    [Parameter(Mandatory)][ValidatePattern('^[a-zA-Z0-9-]+$')][string] $TeamSlug,
    [Parameter(Mandatory)][ValidatePattern('^\d{4}-\d{2}-\d{2}$')][string] $TokenExpires,
    [switch] $TokenFromStdin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this installer as Administrator.'
}
if (-not $TokenFromStdin) { throw 'Supply the token through standard input with -TokenFromStdin.' }
$token = [Console]::ReadLine()
if ([string]::IsNullOrWhiteSpace($token) -or $token -notmatch '^[A-Za-z0-9_-]{20,}$') {
    throw 'No valid token received on standard input.'
}

# Only this exact existing A record is managed. Refuse ambiguous/missing
# records instead of deleting records or creating replacements.
$records = @()
$cursor = $null
$seen = @{}
do {
    $uri = 'https://api.vercel.com/v5/domains/{0}/records?limit=100&slug={1}' -f [Uri]::EscapeDataString($Domain), [Uri]::EscapeDataString($TeamSlug)
    if ($null -ne $cursor) { $uri += '&until=' + [Uri]::EscapeDataString([string]$cursor) }
    try { $page = Invoke-RestMethod -Uri $uri -Headers @{ Authorization = 'Bearer ' + $token } -TimeoutSec 25 }
    catch { throw 'Could not read DNS with the supplied token. Verify its team scope and expiry.' }
    $records += @($page.records | Where-Object { $_.name -eq $Subdomain })
    $cursor = if ($page.PSObject.Properties.Name -contains 'pagination' -and $null -ne $page.pagination -and $page.pagination.PSObject.Properties.Name -contains 'next') { $page.pagination.next } else { $null }
    if ($null -ne $cursor) {
        if ($seen.ContainsKey([string]$cursor)) { throw 'Vercel DNS pagination did not advance.' }
        $seen[[string]$cursor] = $true
    }
} while ($null -ne $cursor)
if ($records.Count -ne 1 -or $records[0].type -ne 'A') {
    throw 'Expected one existing A record; no updater was installed.'
}

$root = Join-Path $env:ProgramData 'yanvpn'
$directory = Join-Path $root 'ddns'
$null = New-Item -ItemType Directory -Path $directory -Force
$acl = [Security.AccessControl.DirectorySecurity]::new()
$acl.SetAccessRuleProtection($true,$false)
foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
        'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
}
Set-Acl -LiteralPath $directory -AclObject $acl
$utf8 = [Text.UTF8Encoding]::new($false)
$tokenPath = Join-Path $directory 'vercel-token.dpapi'
Add-Type -AssemblyName System.Security
$bytes = [Text.Encoding]::UTF8.GetBytes($token)
try {
    $encrypted = [Security.Cryptography.ProtectedData]::Protect($bytes,$null,[Security.Cryptography.DataProtectionScope]::LocalMachine)
    [IO.File]::WriteAllText($tokenPath,[Convert]::ToBase64String($encrypted),$utf8)
} finally { [Array]::Clear($bytes,0,$bytes.Length); $token = $null }
$settingsPath = Join-Path $directory 'vercel-ddns.json'
$settings = [ordered]@{
    Domain = $Domain; Subdomain = $Subdomain; TeamSlug = $TeamSlug
    RecordId = $records[0].id; TokenPath = $tokenPath; TokenExpires = $TokenExpires
}
[IO.File]::WriteAllText($settingsPath,($settings | ConvertTo-Json),$utf8)
$updater = Join-Path $directory 'update-vercel-dns.ps1'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'update-vercel-dns.ps1') -Destination $updater -Force
& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $updater
if ($LASTEXITCODE -ne 0) { throw 'Initial DNS check failed. No new scheduled task was registered.' }

$taskName = 'yanvpn-vercel-ddns'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$updater`"" -WorkingDirectory $directory
$startup = New-ScheduledTaskTrigger -AtStartup
$startup.Delay = 'PT1M'
$repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes 5)
$taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$null = Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($startup,$repeat) -Settings $taskSettings -User 'SYSTEM' -RunLevel Highest -Force
Start-ScheduledTask -TaskName $taskName
Write-Output "Installed ${taskName}: checks $Subdomain.$Domain every five minutes and after boot."
