<#
========================================================================
 Script  : CreateVmRemote.ps1
 Auteur  : Rémy LEPAPE
 Date    : 03/07/2025


 Description :
   Crée une VM Hyper-V distante en générant une ISO cloud-init NoCloud via
   le script Create_Iso_Cidata.ps1. Les opérations sont exécutées
   sur l'hôte distant via Invoke-Command.

========================================================================
#>

<#
.SYNOPSIS
  Crée une VM Hyper-V distante et génère une ISO cloud-init (NoCloud).

.DESCRIPTION
  Le script génère d'abord une ISO NoCloud côté hôte distant en appelant
  Create_Iso_Cidata.ps1. Ensuite, il crée une VM Hyper-V (disque différentiel,
  connexion de l'ISO, désactivation SecureBoot) et démarre la VM.
  Les actions distantes sont réalisées via Invoke-Command.

.PARAMETER VMName
  Nom de la machine virtuelle (ex: vm-test01).

.PARAMETER VHDPath
  Chemin absolu du disque parent (sur l'hôte distant).

.PARAMETER MemoryGB
  Quantité de mémoire à allouer (en Gb).

.PARAMETER IsoPath
  Chemin sur l'hôte distant où sera placé l'ISO générée.

.PARAMETER OscdimgPath
  Chemin vers oscdimg.exe sur l'hôte distant.

.PARAMETER RemoteHost
  Nom ou adresse de l'hôte Hyper-V distant.

.PARAMETER Credential
  PSCredential utilisé pour la connexion distante (Invoke-Command -Credential).

.PARAMETER VmSwitch
  Nom du vSwitch Hyper-V présent sur l'hôte distant.

.PARAMETER NetMode
  'DHCP' ou 'STATIC'. Si 'STATIC', renseigner IpCidr, Gateway, DnsServers.

.PARAMETER IpCidr
  Adresse IP au format CIDR (ex: 192.168.10.50/24) — requis si NetMode = 'STATIC'.

.PARAMETER Gateway
  Passerelle par défaut pour la VM (si STATIC).

.PARAMETER DnsServers
  Liste d'adresses DNS (si STATIC).

.PARAMETER TimeZone
  TimeZone pour cloud-init (par défaut 'UTC').

.PARAMETER Packages
  Liste de paquets à installer via cloud-init (optionnel).

.EXAMPLE
  .\CreateVmRemote.ps1 -VMName vm01 -VHDPath "E:\Base\ubuntu.vhdx" -MemoryGB 2 `
    -IsoPath "E:\Iso" -OscdimgPath "C:\tools\oscdimg.exe" -RemoteHost hyperv01 `
    -Credential (Get-Credential) -VmSwitch "Default Switch" -NetMode DHCP -Verbose

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

# Script de génération ISO
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
        'Password',        # 7  Password
        'admin',           # 8  Username
        $null,             # 9  PasswordHash
        @(),               # 10 SSH keys
        $NetMode,          # 11 'DHCP' / 'STATIC'
        $IpCidr,           # 12
        $Gateway,          # 13
        [object]$DnsServers,  # 14
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

    Write-Host "`n[CRÉATION] VM : $VMName" -ForegroundColor Cyan
    if ($Packages -and $Packages.Count -gt 0) {
        $packagesList = ($Packages | ForEach-Object { "• $_" }) -join "`n  "
        Write-Host "  Packages : `n  $packagesList" -ForegroundColor Yellow
    }
    Write-Host "  Disque   : $VHDPath" -ForegroundColor White
    Write-Host "  Config   : $IsoFull" -ForegroundColor White

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
    Write-Host "[SUCCÈS] VM '$VMName' créée et démarrée" -ForegroundColor Green
}

# Remarque historique :
# Nous passons ici par une variable ScriptBlock au lieu de construire une chaîne
# ScriptBlock inline car certains retours à la ligne et guillemets dans Invoke-Command
# causaient des erreurs de parsing lors de l'exécution distante
Invoke-Command -ComputerName $RemoteHost -Credential $Credential `
  -ScriptBlock $createVmSb `
  -ArgumentList @($VMName, $VHDPath, $MemoryGB, $VmSwitch, $IsoPath)
