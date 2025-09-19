<#
========================================================================
 Script : CreateVmRemote.ps1
 Auteur : LEPAPE Remy
 Date   : 03/07/2025
========================================================================
#>

param(
    [Parameter(Mandatory)][string]$VMName,
    [Parameter(Mandatory)][string]$VHDPath,
    [Parameter(Mandatory)][int]$MemoryGB,
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][string]$OscdimgPath,
    [Parameter(Mandatory)][string]$RemoteHost,
    [Parameter(Mandatory)][pscredential]$Credential,
    [Parameter(Mandatory)][string]$VmSwitch,
    [Parameter(Mandatory)][ValidateSet('DHCP','STATIC')][string]$NetMode,
    [string]$IpCidr,                           # requis si STATIC
    [string]$Gateway,
    [string[]]$DnsServers,
    [string]$TimeZone = 'UTC',
	[string[]]$Packages
)

# Script de génération ISO (à côté de ce .ps1)
$PS_ISO = Join-Path $PSScriptRoot 'Create_Iso_Cidata.ps1'

function New-CloudInitIsoRemote {
    param(
        [string]$RemoteHost,
        [pscredential]$Credential,
        [string]$PS_IsoLocalPath,
        [string]$IsoPath,
        [string]$OscdimgPath,
        [string]$Hostname,
        [string]$Fqdn,
        [string]$TimeZone,
        [ValidateSet('DHCP','STATIC')][string]$NetMode,
        [string]$IpCidr,
        [string]$Gateway,
        [string[]]$DnsServers,
		[string[]]$Packages
    )

    # Dossier temporaire par-VM côté distant (cloud-init seed)
    $TmpDir = Join-Path $IsoPath "tmp\cidata\$Hostname"

    # On évite tout ScriptBlock ici -> on pousse directement le fichier Create_Iso_Cidata.ps1
    Invoke-Command -ComputerName $RemoteHost -Credential $Credential -FilePath $PS_IsoLocalPath -ArgumentList @(
        $IsoPath,          # 1  IsoPath
        $TmpDir,           # 2  TmpDir
        $OscdimgPath,      # 3  oscdimg.exe
        $Hostname,         # 4  Hostname
        $Fqdn,             # 5  FQDN
        $TimeZone,         # 6  TimeZone
        'Password',        # 7  Password (remplace si tu gères un hash)
        'admin',           # 8  Username
        $null,             # 9  PasswordHash
        @(),               # 10 SSH keys
        $NetMode,          # 11 'DHCP' / 'STATIC'
        $IpCidr,           # 12
        $Gateway,          # 13
        [object]$DnsServers,  # 14 (boxing tableau)
		[object]$Packages
    )
}

# --- 1) Génère l'ISO NoCloud sur l'hôte distant ---
New-CloudInitIsoRemote -RemoteHost $RemoteHost -Credential $Credential -PS_IsoLocalPath $PS_ISO `
  -IsoPath $IsoPath -OscdimgPath $OscdimgPath -Hostname $VMName -Fqdn "$VMName.local.fr" `
  -TimeZone $TimeZone -NetMode $NetMode -IpCidr $IpCidr -Gateway $Gateway -DnsServers $DnsServers -Packages $Packages

# --- 2) Crée la VM Hyper-V sur l'hôte distant ---
#Le bout de script envoyé sur la machine distante via la variable $createVmSb 
#createVmSb dans une variable évite ces ambiguïtés et les retours à la ligne piégeux
$createVmSb = {
    param(
        [string]$VMName, [string]$VHDPath, [int]$MemoryGB,
        [string]$VmSwitch, [string]$IsoPath
    )

    $VMRoot       = "E:\BACKUP\VAULTWARDEN_BACKUP\VM TST_"
    $VMPath       = Join-Path $VMRoot $VMName
    $DiffDiskPath = Join-Path $VMPath "$VMName-diff.vhdx"
    $IsoFull      = Join-Path $IsoPath "$VMName.iso"

    Write-Host "DEBUG(remote) VMName=$VMName VHDPath=$VHDPath VMPath=$VMPath ISO=$IsoFull"

    if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
        throw "La VM '$VMName' existe déjà sur l'hôte distant."
    }

    if (-not (Test-Path -LiteralPath $VHDPath)) {
        throw "Disque parent introuvable (distant) : $VHDPath"
    }

    New-Item -ItemType Directory -Path $VMPath -Force | Out-Null
    New-VHD -Path $DiffDiskPath -ParentPath (Resolve-Path $VHDPath) -Differencing | Out-Null

	$MemoryBytes = $MemoryGB * 1GB
    New-VM -Name $VMName -MemoryStartupBytes $MemoryBytes -Generation 2 -VHDPath $DiffDiskPath -Path $VMPath -SwitchName $VmSwitch | Out-Null
    #Attention boot non possible sans désactiver le secureboot
	Set-VMFirmware -VMName $VMName -EnableSecureBoot Off

	#Connection ISO dans VM
    Add-VMDvdDrive -VMName $VMName -Path $IsoFull

    Start-VM -Name $VMName
    Write-Host "VM '$VMName' créée et démarrée (distant)."
}

# Astuce anti-parser: on passe par une variable de ScriptBlock
Invoke-Command -ComputerName $RemoteHost -Credential $Credential `
  -ScriptBlock $createVmSb `
  -ArgumentList @($VMName, $VHDPath, $MemoryGB, $VmSwitch, $IsoPath)
