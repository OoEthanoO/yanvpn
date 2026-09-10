$ErrorActionPreference = 'Continue'
Write-Host 'WMI HomeNet connections'
Get-CimInstance -Namespace root/Microsoft/HomeNet -ClassName HNet_ConnectionProperties |
    Select-Object Connection,IsIcsPublic,IsIcsPrivate | Format-Table -AutoSize
Write-Host 'SharedAccess indexes'
Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\SharedAccess' |
    Select-Object PrivateIndex,PublicIndex,EnableRebootPersistConnection | Format-List
Write-Host 'COM network connections'
$manager = New-Object -ComObject HNetCfg.HNetShare
foreach ($connection in @($manager.EnumEveryConnection())) {
    $properties = $manager.NetConnectionProps.Invoke($connection)
    $sharing = $manager.INetSharingConfigurationForINetConnection.Invoke($connection)
    [pscustomobject]@{
        Name = $properties.Name
        Guid = $properties.Guid
        Status = $properties.Status
        Sharing = $sharing.SharingEnabled
        Type = if ($sharing.SharingEnabled) { $sharing.SharingConnectionType } else { $null }
    }
}
