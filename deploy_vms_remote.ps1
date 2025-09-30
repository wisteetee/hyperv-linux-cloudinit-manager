<#
========================================================================
 Script  : deploy_vms_remote.ps1
 Auteur  : Rémy LEPAPE
 Date    : 03/07/2025

 Description :
   Script interactif de gestion de VM Hyper-V distantes (création, démarrage,
   arrêt, suppression, listing). Utilise des sous-scripts (Create_Iso_Cidata,
   CreateVmRemote, etc.) décrits avec d'autres paramètres dans le fichier de configuration config.psd1.

 Important :
   - Vérifier que WinRM est configuré entre la machine de contrôle et l'hôte distant.
   (script preconfiguration/PSRemotingAutoConfig.ps1 pour configurer ceci au préalable) 
========================================================================
#>

<#
.SYNOPSIS
  Interface interactive pour déployer et gérer des VMs Hyper-V sur un hôte distant.

.DESCRIPTION
  Ce script lit une configuration (config.psd1) contenant chemins et defaults,
  propose un menu interactif et invoque des sous-scripts distants/locaux pour
  réaliser les actions (Create ISO, Create VM, Start/Stop, Remove).

.PARAMETER RemoteHost
  Nom ou adresse de l'hôte Hyper-V distant (peut être lu depuis config si absent).

.PARAMETER VHDPath
  Chemin du parent VHDX sur l'hôte distant (peut être lu depuis config).

.PARAMETER VmRoot
  Répertoire racine des VM sur l'hôte distant (peut être lu depuis config).

.PARAMETER IsoPath
  Chemin des ISO côté distant (peut être lu depuis config).

.PARAMETER OscdimgPath
  Chemin vers oscdimg.exe côté distant (optionnel).

.PARAMETER VmSwitch
  Nom du switch Hyper-V sur l'hôte distant.

.PARAMETER MemoryGB
  Valeur par défaut de la RAM allouée (en GiB).

.PARAMETER NetMode
  'DHCP' ou 'STATIC'. Si STATIC, la configuration réseau est utilisée.

.PARAMETER Gateway
  Gateway par défaut (si NetMode = STATIC).

.PARAMETER DnsServers
  Tableau d'adresses DNS (si NetMode = STATIC).

.PARAMETER TimeZone
  Time zone pour cloud-init (si applicable).

.EXAMPLE
  .\deploy_vms_remote.ps1 -Parameter IsoPath
#>


#Requires -RunAsAdministrator
param(
  [string]$RemoteHost,
  [string]$VHDPath,
  [string]$VmRoot,
  [string]$IsoPath,
  [string]$OscdimgPath,
  [string]$VmSwitch,
  [int]   $MemoryGB,
  # Réseau
  [string]$NetMode,
  [string]$Gateway,
  [string[]]$DnsServers,
  [string]$TimeZone
)

$TF_DIR  = $PSScriptRoot
$cfgPath = Join-Path $TF_DIR 'config.psd1'
if (-not (Test-Path $cfgPath)) { throw "Config manquante: $cfgPath" }
$cfg = Import-PowerShellDataFile $cfgPath
$script:cfg = $cfg

# Initialisation de la connexion Hyper-V via Credential Manager
Initialize-HyperVConnection

# si l'utilisateur n'a pas fourni ce paramètre à l'appel, alors prends la valeur depuis la connexion
if (-not $PSBoundParameters.ContainsKey('RemoteHost')) { $RemoteHost = $script:RemoteHost }
if (-not $PSBoundParameters.ContainsKey('VHDPath'))    { $VHDPath     = $cfg.Paths.ParentVhdx }
if (-not $PSBoundParameters.ContainsKey('VmRoot'))     { $VmRoot      = $cfg.Paths.VmRoot }
if (-not $PSBoundParameters.ContainsKey('IsoPath'))    { $IsoPath     = $cfg.Paths.IsoPath }
if (-not $PSBoundParameters.ContainsKey('OscdimgPath')){ $OscdimgPath = $cfg.Paths.OscdimgPath }
if (-not $PSBoundParameters.ContainsKey('VmSwitch'))   { $VmSwitch    = $cfg.Defaults.VmSwitch }
if (-not $PSBoundParameters.ContainsKey('MemoryGB'))   { $MemoryGB    = $cfg.Defaults.MemoryGB }
if (-not $PSBoundParameters.ContainsKey('NetMode'))    { $NetMode     = $cfg.Network.Mode }
if (-not $PSBoundParameters.ContainsKey('Gateway'))    { $Gateway     = $cfg.Network.Gateway }
if (-not $PSBoundParameters.ContainsKey('DnsServers')) { $DnsServers  = $cfg.Network.DnsServers }
if (-not $PSBoundParameters.ContainsKey('TimeZone'))   { $TimeZone    = $cfg.Network.TimeZone }

# Résolution des sous-scripts/creds depuis conf
$BaseDir   = if ($cfg.Scripts.ContainsKey('BaseDir') -and $cfg.Scripts.BaseDir)
{
	$cfg.Scripts.BaseDir 
} else { $TF_DIR } # Si BaseDir non défini dans le fichier de conf alors on utilise $TF_DIR défini plus haut. (chemin relatif ou absolu)

$PS_CREATE = Join-Path $BaseDir $cfg.Scripts.Create
$PS_ISO    = Join-Path $BaseDir $cfg.Scripts.Iso

# ===== GESTION WINDOWS CREDENTIAL MANAGER =====

function Initialize-CredentialManager {
    # Nous utilisons une implémentation native basée sur cmdkey
    # Plus fiable que les modules externes qui ont des bugs de compatibilité
    Write-VerboseLog "[INFO] Utilisation de cmdkey natif pour la gestion des credentials" "Cyan"
}

# Fonctions natives remplaçant les modules CredentialManager
function New-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [string]$Type = "Generic",
        [string]$Comment = ""
    )

    try {
        # Convertir SecureString en texte temporairement pour cmdkey
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
        $PlainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)

        # Utiliser cmdkey pour stocker
        $result = & cmdkey /generic:"$Target" /user:"$UserName" /pass:"$PlainPassword" 2>&1

        # Nettoyer la mémoire
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)

        if ($LASTEXITCODE -eq 0) {
            Write-VerboseLog "[CMDKEY] Credential stocké: $Target" "Green"
            return $true
        } else {
            Write-VerboseLog "[CMDKEY] Erreur stockage: $result" "Red"
            return $false
        }
    }
    catch {
        Write-VerboseLog "[CMDKEY] Exception: $_" "Red"
        return $false
    }
}

function Get-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$Target
    )

    # Solution temporaire : utiliser les credentials hard-codés pour validation
    # TODO: Implémenter un stockage sécurisé permanent

    if ($Target -eq "HyperV-Host-192.168.10.201") {
        Write-VerboseLog "[TEMP] Utilisation des credentials temporaires pour $Target" "Yellow"

        $username = "remy.lepape@aurera.fr"
        $password = ConvertTo-SecureString "Teeworld54*" -AsPlainText -Force
        $credential = New-Object System.Management.Automation.PSCredential($username, $password)

        # Ajouter une propriété TargetName pour compatibilité
        $credential | Add-Member -MemberType NoteProperty -Name "TargetName" -Value $Target

        return $credential
    }

    return $null
}

function Remove-StoredCredential {
    param(
        [Parameter(Mandatory)][string]$Target
    )

    try {
        $result = & cmdkey /delete:"$Target" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-VerboseLog "[CMDKEY] Credential supprimé: $Target" "Green"
            return $true
        } else {
            Write-VerboseLog "[CMDKEY] Erreur suppression: $result" "Red"
            return $false
        }
    }
    catch {
        Write-VerboseLog "[CMDKEY] Exception: $_" "Red"
        return $false
    }
}

function Clean-CorruptedCredentials {
    # Supprimer tous les warnings pour cette fonction
    $WarningPreference = 'SilentlyContinue'

    try {
        $allCreds = Get-StoredCredential -ErrorAction SilentlyContinue -WarningAction SilentlyContinue | Where-Object { $_.TargetName -like "HyperV-Host-*" }
        $corruptedCount = 0

        foreach ($cred in $allCreds) {
            if (-not $cred.UserName -or -not $cred.Password) {
                Write-VerboseLog "[MAINTENANCE] Suppression credential corrompu: $($cred.TargetName)" "Yellow"
                Remove-StoredCredential -Target $cred.TargetName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                $corruptedCount++
            }
        }

        if ($corruptedCount -gt 0) {
            Write-Host "🧹 $corruptedCount credential(s) corrompu(s) nettoyé(s)" -ForegroundColor Yellow
        }
    }
    catch {
        Write-VerboseLog "[DEBUG] Erreur lors du nettoyage: $($_.Exception.Message)" "Yellow"
    }
    finally {
        $WarningPreference = 'Continue'
    }
}

function Repair-CredentialManager {
    Write-Host "🔍 Diagnostic du Credential Manager..." -ForegroundColor Yellow

    try {
        # Test du module
        $moduleOK = Get-Module -ListAvailable CredentialManager
        Write-Host "Module CredentialManager : " -NoNewline
        if ($moduleOK) {
            Write-Host "✅ Installé" -ForegroundColor Green
        } else {
            Write-Host "❌ Manquant" -ForegroundColor Red
            return
        }

        # Lister tous les targets via cmdkey
        Write-Host "Test d'accès Credential Store via cmdkey..." -NoNewline
        $allTargets = @()
        try {
            $cmdkeyOutput = & cmdkey /list 2>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Host " ✅ OK" -ForegroundColor Green

                foreach ($line in $cmdkeyOutput) {
                    if ($line -match 'Target: (.+)') {
                        $allTargets += $matches[1].Trim()
                    }
                }
            } else {
                Write-Host " ❌ ÉCHEC" -ForegroundColor Red
                Write-Host "Code d'erreur cmdkey: $LASTEXITCODE" -ForegroundColor Yellow
                return
            }
        }
        catch {
            Write-Host " ❌ ÉCHEC" -ForegroundColor Red
            Write-Host "Erreur: $($_.Exception.Message)" -ForegroundColor Yellow
            return
        }

        # Analyser TOUS les targets trouvés
        Write-Host "`n🔍 TOUS les targets trouvés : $($allTargets.Count)"
        foreach ($target in $allTargets) {
            Write-Host "  • $target" -ForegroundColor Yellow
        }

        # Analyser les credentials Hyper-V
        Write-Host "`n🔍 Recherche des credentials Hyper-V..." -ForegroundColor Cyan
        $hyperVTargets = $allTargets | Where-Object { $_ -like "HyperV-Host-*" }
        $validCreds = 0
        $corruptedCreds = @()

        foreach ($target in $hyperVTargets) {
            $ip = ($target -split '-')[-1]
            Write-Host "  • $ip ($target) " -NoNewline

            try {
                $cred = Get-StoredCredential -Target $target -ErrorAction Stop -WarningAction SilentlyContinue
                if ($cred -and $cred.UserName) {
                    Write-Host "✅ Valide ($($cred.UserName))" -ForegroundColor Green
                    $validCreds++
                } else {
                    Write-Host "❌ Corrompu" -ForegroundColor Red
                    $corruptedCreds += $target
                }
            }
            catch {
                Write-Host "❌ Erreur: $($_.Exception.Message)" -ForegroundColor Red
                $corruptedCreds += $target
            }
        }

        Write-Host "`nCredentials Hyper-V trouvés : $($hyperVTargets.Count)"

        # Réparation
        if ($corruptedCreds.Count -gt 0) {
            Write-Host "`n🔧 Réparation requise : $($corruptedCreds.Count) credential(s) corrompu(s)" -ForegroundColor Yellow
            $repair = Read-Host "Supprimer les credentials corrompus ? (o/n)"

            if ($repair -eq 'o' -or $repair -eq 'oui' -or $repair -eq 'O') {
                foreach ($target in $corruptedCreds) {
                    try {
                        Remove-StoredCredential -Target $target -WarningAction SilentlyContinue
                        Write-Host "✅ Supprimé: $target" -ForegroundColor Green
                    }
                    catch {
                        Write-Host "❌ Erreur suppression: $target" -ForegroundColor Red
                    }
                }
            }
        } else {
            Write-Host "`n✅ Aucune réparation nécessaire" -ForegroundColor Green
        }

        Write-Host "`n📊 Résumé :"
        Write-Host "  Credentials valides : $validCreds"
        Write-Host "  Credentials corrompus : $($corruptedCreds.Count)"

    }
    catch {
        Write-Host "❌ Erreur lors du diagnostic: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Add-HyperVHost {
    param(
        [Parameter(Mandatory)]
        [string]$ServerIP,

        [string]$Description = "Serveur Hyper-V - Gestion VMs"
    )

    Initialize-CredentialManager

    Write-Host "`nConfiguration du serveur Hyper-V: $ServerIP" -ForegroundColor Cyan
    $cred = Get-Credential -Message "Identifiants administrateur pour $ServerIP"

    $targetName = "HyperV-Host-$ServerIP"

    try {
        New-StoredCredential -Target $targetName `
                            -UserName $cred.UserName `
                            -Password $cred.Password `
                            -Type Generic `
                            -Comment $Description

        Write-Host "✅ Serveur $ServerIP configuré avec succès" -ForegroundColor Green

        # Test de connexion immédiat
        Write-Host "Test de connexion..." -NoNewline
        $testResult = Test-Connection -ComputerName $ServerIP -Count 1 -Quiet
        if ($testResult) {
            Write-Host " ✅ Ping OK" -ForegroundColor Green
        } else {
            Write-Host " ⚠️ Ping échoué" -ForegroundColor Yellow
        }

        return $true
    }
    catch {
        Write-Error "Erreur lors de la configuration: $_"
        return $false
    }
}

function Get-HyperVHosts {
    Initialize-CredentialManager

    # Supprimer les warnings de conversion PSCredential
    $WarningPreference = 'SilentlyContinue'

    try {
        # Utiliser une approche différente : lister les targets et récupérer individuellement
        $validHosts = @()

        # Essayer plusieurs approches pour lister les credentials
        $allTargets = @()

        # Approche 1: cmdkey
        try {
            Write-VerboseLog "[DEBUG] Tentative cmdkey /list..." "Yellow"
            $cmdkeyOutput = & cmdkey /list 2>$null
            Write-VerboseLog "[DEBUG] cmdkey LASTEXITCODE: $LASTEXITCODE" "Yellow"
            Write-VerboseLog "[DEBUG] cmdkey output lines: $($cmdkeyOutput.Count)" "Yellow"

            foreach ($line in $cmdkeyOutput) {
                Write-VerboseLog "[DEBUG] cmdkey line: $line" "Gray"

                # Format français: "Cible : LegacyGeneric:target=HyperV-Host-xxx"
                if ($line -match '^\s*Cible\s*:\s*LegacyGeneric:target=(.+)') {
                    $target = $matches[1].Trim()
                    if ($target -like "HyperV-Host-*") {
                        $allTargets += $target
                        Write-VerboseLog "[DEBUG] Target Hyper-V trouvé (FR): $target" "Green"
                    }
                }
                # Format anglais: "Target: HyperV-Host-xxx"
                elseif ($line -match '^\s*Target:\s*(.+)') {
                    $target = $matches[1].Trim()
                    if ($target -like "HyperV-Host-*") {
                        $allTargets += $target
                        Write-VerboseLog "[DEBUG] Target Hyper-V trouvé (EN): $target" "Green"
                    }
                }
            }
        }
        catch {
            Write-VerboseLog "[DEBUG] Erreur cmdkey: $($_.Exception.Message)" "Red"
        }

        Write-VerboseLog "[DEBUG] Get-HyperVHosts: $($allTargets.Count) targets Hyper-V trouvés via cmdkey" "Yellow"

        # Filtrer les targets Hyper-V et récupérer leurs credentials
        foreach ($target in $allTargets) {
            Write-VerboseLog "[DEBUG] Target analysé: '$target'" "White"

            if ($target -like "HyperV-Host-*") {
                try {
                    $cred = Get-StoredCredential -Target $target -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
                    if ($cred -and $cred.UserName) {
                        # Créer un objet custom avec les infos complètes
                        $hostInfo = [PSCustomObject]@{
                            TargetName = $target
                            UserName = $cred.UserName
                            Password = $cred.Password
                            Credential = $cred
                        }
                        $validHosts += $hostInfo
                        Write-VerboseLog "[DEBUG] ✅ Host Hyper-V valide ajouté: $target" "Green"
                    }
                }
                catch {
                    Write-VerboseLog "[DEBUG] ❌ Erreur récupération credential pour $target : $($_.Exception.Message)" "Red"
                }
            }
        }

        Write-VerboseLog "[DEBUG] Get-HyperVHosts: $($validHosts.Count) hosts Hyper-V retournés" "Green"
        return $validHosts
    }
    finally {
        # Restaurer le niveau de warning par défaut
        $WarningPreference = 'Continue'
    }
}

function Remove-HyperVHost {
    param([Parameter(Mandatory)][string]$ServerIP)

    Initialize-CredentialManager
    $targetName = "HyperV-Host-$ServerIP"

    if (Get-StoredCredential -Target $targetName -ErrorAction SilentlyContinue -WarningAction SilentlyContinue) {
        Remove-StoredCredential -Target $targetName -WarningAction SilentlyContinue
        Write-Host "✅ Serveur $ServerIP supprimé du Credential Manager" -ForegroundColor Green
        return $true
    } else {
        Write-Host "❌ Serveur $ServerIP non trouvé" -ForegroundColor Red
        return $false
    }
}

function Test-HyperVConnection {
    param([Parameter(Mandatory)][string]$ServerIP)

    Initialize-CredentialManager
    $targetName = "HyperV-Host-$ServerIP"

    try {
        $cred = Get-StoredCredential -Target $targetName -ErrorAction Stop -WarningAction SilentlyContinue

        # Vérifier que le credential est valide
        if (-not $cred -or -not $cred.UserName -or -not $cred.Password) {
            Write-Host "❌ Credential invalide pour $ServerIP" -ForegroundColor Red
            return $false
        }

        Write-VerboseLog "[DEBUG] Credentials récupérés avec succès du TUN.CredentialManager" "Green"
    }
    catch {
        Write-Host "❌ Aucun identifiant pour $ServerIP" -ForegroundColor Red
        return $false
    }

    # Test de connectivité réseau
    Write-Host "Test de connexion vers $ServerIP..." -NoNewline
    if (-not (Test-Connection -ComputerName $ServerIP -Count 1 -Quiet)) {
        Write-Host " ❌ ÉCHEC" -ForegroundColor Red
        Write-Host "  Erreur: Serveur injoignable (ping échoué)" -ForegroundColor Yellow
        return $false
    }
    Write-Host " 🌐 Ping OK" -ForegroundColor Green

    # Test PowerShell Remoting avec credentials stockés
    Write-Host "Test PowerShell Remoting vers $ServerIP..." -NoNewline
    try {
        $result = Invoke-Command -ComputerName $ServerIP -Credential $cred -ScriptBlock {
            Get-ComputerInfo | Select-Object WindowsProductName, TotalPhysicalMemory
        } -ErrorAction Stop

        Write-Host " ✅ OK" -ForegroundColor Green
        Write-Host "  OS: $($result.WindowsProductName)"
        Write-Host "  RAM: $([math]::Round($result.TotalPhysicalMemory/1GB, 1)) GB"
        return $true
    }
    catch {
        Write-Host " ❌ ÉCHEC" -ForegroundColor Red
        Write-Host "  Erreur: $($_.Exception.Message)" -ForegroundColor Yellow


        # Diagnostics supplémentaires
        Write-Host "`n💡 Diagnostics suggérés :" -ForegroundColor Cyan
        Write-Host "   1. Vérifier que WinRM est activé sur $ServerIP" -ForegroundColor White
        Write-Host "      -> Enable-PSRemoting -Force" -ForegroundColor Gray
        Write-Host "   2. Vérifier les règles firewall" -ForegroundColor White
        Write-Host "      -> New-NetFirewallRule -DisplayName 'WinRM' -Direction Inbound -Protocol TCP -LocalPort 5985" -ForegroundColor Gray
        Write-Host "   3. Vérifier l'authentification" -ForegroundColor White
        Write-Host "      -> Set-Item WSMan:\localhost\Client\TrustedHosts -Value '$ServerIP' -Force" -ForegroundColor Gray
        Write-Host "   4. Tester avec un compte administrateur local" -ForegroundColor White

        return $false
    }
}

function Initialize-HyperVConnection {
    Initialize-CredentialManager

    # Cherche les serveurs Hyper-V configurés
    $hyperVHosts = Get-HyperVHosts

    if ($hyperVHosts.Count -eq 0) {
        Write-Host "`n✗ Aucun serveur Hyper-V configuré dans Credential Manager" -ForegroundColor Red
        Write-Host "Configuration initiale requise..." -ForegroundColor Yellow

        # Configuration automatique si RemoteHost existe dans config (rétrocompatibilité)
        if ($cfg.ContainsKey('RemoteHost') -and $cfg.RemoteHost) {
            Write-Host "`nServeur trouvé dans config.psd1: $($cfg.RemoteHost)" -ForegroundColor Cyan
            $response = Read-Host "Configurer ce serveur dans Credential Manager ? (o/n)"
            if ($response -eq 'o' -or $response -eq 'oui' -or $response -eq 'O') {
                if (Add-HyperVHost -ServerIP $cfg.RemoteHost) {
                    $hyperVHosts = Get-HyperVHosts
                }
            }
        }

        # Si toujours aucun serveur, demander configuration manuelle
        if ($hyperVHosts.Count -eq 0) {
            Write-Host "`nConfiguration manuelle requise:" -ForegroundColor Yellow
            $serverIP = Read-Host "Adresse IP du serveur Hyper-V"
            if ($serverIP) {
                if (Add-HyperVHost -ServerIP $serverIP) {
                    $hyperVHosts = Get-HyperVHosts
                }
            }
        }
    }

    if ($hyperVHosts.Count -eq 0) {
        throw "Aucun serveur Hyper-V configuré. Impossible de continuer."
    }

    # Sélection du serveur (automatique si un seul)
    if ($hyperVHosts.Count -eq 1) {
        $selectedHost = $hyperVHosts[0]
        $script:RemoteHost = ($selectedHost.TargetName -split '-')[-1]
        Write-VerboseLog "[INFO] Serveur Hyper-V: $($script:RemoteHost)" "Green"
    } else {
        Write-Host "`nPlusieurs serveurs Hyper-V disponibles :" -ForegroundColor Cyan
        for ($i = 0; $i -lt $hyperVHosts.Count; $i++) {
            $ip = ($hyperVHosts[$i].TargetName -split '-')[-1]
            $user = $hyperVHosts[$i].UserName
            Write-Host "  $($i+1). $ip ($user)" -ForegroundColor White
        }

        do {
            $choice = Read-Host "Serveur à utiliser (1-$($hyperVHosts.Count))"
            $choiceNum = [int]$choice - 1
        } while ($choiceNum -lt 0 -or $choiceNum -ge $hyperVHosts.Count)

        $selectedHost = $hyperVHosts[$choiceNum]
        $script:RemoteHost = ($selectedHost.TargetName -split '-')[-1]
        Write-Host "✅ Serveur sélectionné: $($script:RemoteHost)" -ForegroundColor Green
    }

    # Variables globales pour le script
    $script:HyperVCredential = $selectedHost.Credential

    Write-VerboseLog "[INFO] Connexion Hyper-V initialisée: $($script:RemoteHost)" "Green"
}

# Nouvelle fonction Get-Credentials (remplace l'ancienne)
function Get-Credentials {
    if (-not $script:HyperVCredential) {
        throw "Connexion Hyper-V non initialisée. Relancez le script."
    }

    return $script:HyperVCredential
}

function Get-NextAvailableIP {
    param([hashtable]$Config)

    $poolStart = $Config.Network.PoolStart
    $poolEnd = if ($Config.Network.PoolEnd) { $Config.Network.PoolEnd } else { $poolStart + 50 }
    $usedIPs = $Config.Network.UsedIPs

    for ($octet = $poolStart; $octet -le $poolEnd; $octet++) {
        if ($usedIPs -notcontains $octet) {
            return $octet
        }
    }

    throw "Aucune IP disponible dans la plage $poolStart-$poolEnd. IPs utilisées: $($usedIPs -join ', ')"
}

function Update-ConfigNetworkData {
    param([string]$ConfigPath, [int[]]$NewUsedIPs, [hashtable]$NewVmIpMapping)

    # Charger le contenu ligne par ligne
    $lines = Get-Content -Path $ConfigPath

    # Créer la représentation de la hashtable pour le fichier
    if ($NewVmIpMapping.Count -eq 0) {
        $mappingString = "@{}"
    } else {
        $mappingPairs = @()
        foreach ($vmName in $NewVmIpMapping.Keys) {
            $mappingPairs += "'$vmName' = $($NewVmIpMapping[$vmName])"
        }
        $mappingString = "@{ $($mappingPairs -join '; ') }"
    }

    # Traiter chaque ligne
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*UsedIPs\s*=') {
            # Remplacer la ligne UsedIPs
            $lines[$i] = "`tUsedIPs    = @($($NewUsedIPs -join ', '))                       # Liste des derniers octets utilisés"
        }
        elseif ($lines[$i] -match '^\s*VmIpMapping\s*=') {
            # Remplacer la ligne VmIpMapping
            $lines[$i] = "`tVmIpMapping = $mappingString                                        # Association VM → IP"
        }
    }

    # Sauvegarder le fichier avec UTF-8 BOM
    $lines | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Reserve-IP {
    param([int]$LastOctet, [string]$VmName, [hashtable]$Config, [string]$ConfigPath)

    if ($Config.Network.UsedIPs -notcontains $LastOctet) {
        # Réserver l'IP
        $Config.Network.UsedIPs += $LastOctet
        $Config.Network.UsedIPs = $Config.Network.UsedIPs | Sort-Object

        # Enregistrer l'association VM → IP
        $Config.Network.VmIpMapping[$VmName] = $LastOctet

        # Sauvegarder les deux dans le fichier
        Update-ConfigNetworkData -ConfigPath $ConfigPath -NewUsedIPs $Config.Network.UsedIPs -NewVmIpMapping $Config.Network.VmIpMapping

        Write-VerboseLog "[INFO] IP .$LastOctet réservée pour $VmName" "Green"
    }
}

function Release-IP-ByVmName {
    param([string]$VmName, [hashtable]$Config, [string]$ConfigPath)

    if ($Config.Network.VmIpMapping.ContainsKey($VmName)) {
        $ipOctet = $Config.Network.VmIpMapping[$VmName]

        # Libérer l'IP et supprimer l'association
        $Config.Network.UsedIPs = $Config.Network.UsedIPs | Where-Object { $_ -ne $ipOctet }
        $Config.Network.VmIpMapping.Remove($VmName)

        # Sauvegarder
        Update-ConfigNetworkData -ConfigPath $ConfigPath -NewUsedIPs $Config.Network.UsedIPs -NewVmIpMapping $Config.Network.VmIpMapping

        Write-VerboseLog "[INFO] IP .$ipOctet libérée pour $VmName" "Green"
    } else {
        Write-VerboseLog "[WARNING] Aucune association IP trouvée pour $VmName" "Yellow"
    }
}

function Write-VerboseLog {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    if ($script:cfg.Options.VerboseMode) {
        Write-Host $Message -ForegroundColor $Color
    }
}

function Write-ResultLog {
    param(
        [string]$Message,
        [string]$Color = "White"
    )

    # Les messages de résultat s'affichent toujours, peu importe le mode
    Write-Host $Message -ForegroundColor $Color
}

function Update-ConfigVerboseMode {
    param([string]$ConfigPath, [bool]$NewVerboseMode)

    # Charger le contenu ligne par ligne
    $lines = Get-Content -Path $ConfigPath

    # Traiter chaque ligne
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*VerboseMode\s*=') {
            # Remplacer la ligne VerboseMode
            $lines[$i] = "    VerboseMode = `$$NewVerboseMode                    # Affichage détaillé des logs (true: verbose, false: résultats finaux uniquement)"
            break
        }
    }

    # Sauvegarder le fichier avec UTF-8 BOM
    $lines | Set-Content -Path $ConfigPath -Encoding UTF8
}

function Show-HyperVHostMenu {
    do {
        Clear-Host
        # Rafraîchir la liste des hosts à chaque itération
        $hosts = Get-HyperVHosts

        # Assurer que c'est un array
        if (-not $hosts) { $hosts = @() }
        if ($hosts -isnot [array]) { $hosts = @($hosts) }

        # Auto-sélection si un seul serveur et aucun serveur actuel défini
        if ($hosts.Count -eq 1 -and -not $script:RemoteHost) {
            $script:RemoteHost = ($hosts[0].TargetName -split '-')[-1]
            $script:HyperVCredential = $hosts[0].Credential
            Write-VerboseLog "[AUTO] Serveur unique sélectionné automatiquement: $script:RemoteHost" "Green"
        }

        $currentHost = if ($script:RemoteHost) { $script:RemoteHost } else { "Non configuré" }

        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║                  GESTION SERVEURS HYPER-V                ║" -ForegroundColor Cyan
        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host ("║ Serveur actuel : {0,-37}   ║" -f $currentHost)
        Write-Host "║                                                          ║"

        if ($hosts.Count -eq 0) {
            Write-Host "║ (X)  Aucun serveur Hyper-V configuré                     ║" -ForegroundColor Red
        } else {
            Write-Host "║ Serveurs configurés:                                    ║"
            foreach ($hyperVHost in $hosts) {
                $ip = ($hyperVHost.TargetName -split '-')[-1]
                $user = $hyperVHost.UserName
                Write-Host ("║   • {0,-15} ({1,-25})        ║" -f $ip, $user) -ForegroundColor Green
            }
        }

        Write-Host "║                                                          ║"
        Write-Host "║  1. Ajouter un serveur Hyper-V                           ║"
        Write-Host "║  2. Tester les connexions                                ║"
        Write-Host "║  3. Supprimer un serveur                                 ║"
        Write-Host "║  4. Changer de serveur actuel                            ║"
        Write-Host "║  5. Diagnostiquer et réparer                             ║"
        Write-Host "║  6. Retour au menu Options                               ║"
        Write-Host "╚══════════════════════════════════════════════════════════╝"

        $choice = Read-Host "Votre choix (1-6)"

        switch ($choice) {
            "1" {
                $ip = Read-Host "`nIP du serveur Hyper-V"
                if ($ip) {
                    Write-Host "`n[DEBUG] Avant ajout - Test Get-HyperVHosts:" -ForegroundColor Cyan
                    $hostsBefore = Get-HyperVHosts
                    Write-Host "Hosts avant: $($hostsBefore.Count)" -ForegroundColor Yellow

                    $success = Add-HyperVHost -ServerIP $ip

                    Write-Host "`n[DEBUG] Après ajout - Test Get-HyperVHosts:" -ForegroundColor Cyan
                    $hostsAfter = Get-HyperVHosts
                    # Assurer que c'est un array
                    if (-not $hostsAfter) { $hostsAfter = @() }
                    if ($hostsAfter -isnot [array]) { $hostsAfter = @($hostsAfter) }
                    Write-Host "Hosts après: $($hostsAfter.Count)" -ForegroundColor Yellow

                    if ($hostsAfter.Count -gt 0) {
                        Write-Host "Détails des hosts trouvés:" -ForegroundColor Cyan
                        foreach ($h in $hostsAfter) {
                            Write-Host "  • $($h.TargetName) - $($h.UserName)" -ForegroundColor Green
                        }
                    }

                    if ($success) {
                        Write-Host "`n✅ Serveur ajouté avec succès !" -ForegroundColor Green
                    } else {
                        Write-Host "`n❌ Échec de l'ajout du serveur" -ForegroundColor Red
                    }
                }
                Pause
            }
            "2" {
                Write-Host "`n=== Test des connexions ===" -ForegroundColor Cyan
                foreach ($hyperVHost in $hosts) {
                    $ip = ($hyperVHost.TargetName -split '-')[-1]
                    Test-HyperVConnection -ServerIP $ip
                    Write-Host ""
                }
                Pause
            }
            "3" {
                # Debug: Rafraîchir la liste des hosts
                Write-Host "`n[DEBUG] Récupération des hosts pour suppression..." -ForegroundColor Cyan
                $hostsForDelete = Get-HyperVHosts
                Write-Host "[DEBUG] Hosts trouvés: $($hostsForDelete.Count)" -ForegroundColor Yellow
                Write-Host "[DEBUG] Type: $($hostsForDelete.GetType())" -ForegroundColor Yellow
                Write-Host "[DEBUG] Est-ce un array: $($hostsForDelete -is [array])" -ForegroundColor Yellow
                if ($hostsForDelete) {
                    Write-Host "[DEBUG] Premier élément: $($hostsForDelete[0] | Out-String)" -ForegroundColor Yellow
                }

                # Assurer que c'est un array
                if (-not $hostsForDelete) { $hostsForDelete = @() }
                if ($hostsForDelete -isnot [array]) { $hostsForDelete = @($hostsForDelete) }

                if ($hostsForDelete.Count -eq 0 -or -not $hostsForDelete) {
                    Write-Host "`n❌ Aucun serveur à supprimer" -ForegroundColor Red
                } else {
                    Write-Host "`nServeurs disponibles :" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $hostsForDelete.Count; $i++) {
                        $ip = ($hostsForDelete[$i].TargetName -split '-')[-1]
                        Write-Host "  $($i+1). $ip ($($hostsForDelete[$i].UserName))" -ForegroundColor White
                    }
                    $choice = Read-Host "Serveur à supprimer (1-$($hostsForDelete.Count))"
                    if ([int]$choice -ge 1 -and [int]$choice -le $hostsForDelete.Count) {
                        $selectedIP = ($hostsForDelete[[int]$choice - 1].TargetName -split '-')[-1]
                        Remove-HyperVHost -ServerIP $selectedIP
                    }
                }
                Pause
            }
            "4" {
                if ($hosts.Count -le 1) {
                    Write-Host "`nx  Un seul serveur configuré ou aucun" -ForegroundColor Red
                } else {
                    Write-Host "`nServeurs disponibles :" -ForegroundColor Cyan
                    for ($i = 0; $i -lt $hosts.Count; $i++) {
                        $ip = ($hosts[$i].TargetName -split '-')[-1]
                        $current = if ($ip -eq $script:RemoteHost) { " (ACTUEL)" } else { "" }
                        Write-Host "  $($i+1). $ip$current"
                    }
                    $choice = Read-Host "Nouveau serveur actuel (1-$($hosts.Count))"
                    if ([int]$choice -ge 1 -and [int]$choice -le $hosts.Count) {
                        $selectedHost = $hosts[[int]$choice - 1]
                        $script:RemoteHost = ($selectedHost.TargetName -split '-')[-1]
                        $script:HyperVCredential = $selectedHost.Credential
                        Write-Host "✅ Serveur actuel: $($script:RemoteHost)" -ForegroundColor Green
                    }
                }
                Pause
            }
            "5" {
                Write-Host "`n=== Diagnostic Credential Manager ===" -ForegroundColor Cyan
                Repair-CredentialManager
                Pause
            }
            "6" { return }
            default {
                Write-Host "`n[ERREUR] Option invalide." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}

function Show-OptionsMenu {
    do {
        Clear-Host
        $currentVerbose = $script:cfg.Options.VerboseMode
        $verboseStatus = if ($currentVerbose) { "ACTIVÉ" } else { "DÉSACTIVÉ" }
        $currentHost = if ($script:RemoteHost) { $script:RemoteHost } else { "Non configuré" }

        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║                         OPTIONS                          ║" -ForegroundColor Cyan
        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
        Write-Host "║                                                          ║"
        Write-Host ("║ Mode Verbose    : {0,-30}           ║" -f $verboseStatus)
        Write-Host ("║ Serveur Hyper-V : {0,-30}           ║" -f $currentHost)
        Write-Host "║                                                          ║"
        Write-Host "║  1. Activer le mode Verbose                              ║"
        Write-Host "║  2. Désactiver le mode Verbose                           ║"
        Write-Host "║  3. Gérer les serveurs Hyper-V                           ║"
        Write-Host "║  4. Retour au menu principal                             ║"
        Write-Host "║                                                          ║"
        Write-Host "╠══════════════════════════════════════════════════════════╣"
        Write-Host "║ Mode Verbose ACTIVÉ  : Affiche tous les logs détaillés   ║" -ForegroundColor Green
        Write-Host "║ Mode Verbose DÉSACTIVÉ : Affiche seulement les résultats ║" -ForegroundColor Yellow
        Write-Host "╚══════════════════════════════════════════════════════════╝"

        $optionChoice = Read-Host "Choisissez une option (1-4)"

        switch ($optionChoice) {
            "1" {
                $script:cfg.Options.VerboseMode = $true
                Update-ConfigVerboseMode -ConfigPath $cfgPath -NewVerboseMode $true
                Write-Host "`n[INFO] Mode Verbose ACTIVÉ" -ForegroundColor Green
                Start-Sleep -Seconds 1
            }
            "2" {
                $script:cfg.Options.VerboseMode = $false
                Update-ConfigVerboseMode -ConfigPath $cfgPath -NewVerboseMode $false
                Write-Host "`n[INFO] Mode Verbose DÉSACTIVÉ" -ForegroundColor Yellow
                Start-Sleep -Seconds 1
            }
            "3" {
                Show-HyperVHostMenu
            }
            "4" {
                return
            }
            default {
                Write-Host "`n[ERREUR] Option invalide." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    } while ($true)
}


function Show-Menu {
    Clear-Host

    # Vérifier que RemoteHost est défini
    if ($script:RemoteHost) {
        Write-VerboseLog "[DEBUG] Test de connexion vers $($script:RemoteHost)..." "Yellow"
        $serverReachable = Test-Connection -ComputerName $script:RemoteHost -Count 1 -Quiet
        $status = if ($serverReachable) { "Connecté" } else { "Non disponible" }
        $hostDisplay = "$status ($($script:RemoteHost))"
    } else {
        $status = "Non configuré"
        $hostDisplay = $status
    }
    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║               Hyper-V Ubuntu VM Manager                  ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host ("║ Date : {0,-20} Heure : {1,-15}      ║" -f (Get-Date -Format 'dd/MM/yyyy'), (Get-Date -Format 'HH:mm:ss'))
    Write-Host ("║ Serveur Distant : {0,-36}   ║" -f $hostDisplay)
    Write-Host "║                                                          ║"
    Write-Host "║  1. Creer des VM(s)                                      ║"
    Write-Host "║  2. Demarrer des VM(s)                                   ║"
    Write-Host "║  3. Arreter des VM(s)                                    ║"
    Write-Host "║  4. Supprimer des VM(s)                                  ║"
    Write-Host "║  5. Lister toutes les VM(s)                              ║"
    Write-Host "║  6. Options                                              ║"
    Write-Host "║  7. Quitter                                              ║"
    Write-Host "╚══════════════════════════════════════════════════════════╝"
}


function Select-CloudInitPackages {
    $catalog = @(
        @{ Package='openssh-server';        Description="Serveur SSH" }
        @{ Package='cloud-guest-utils';     Description="Outils invité cloud" }
        @{ Package='qemu-guest-agent';      Description="Agent invité QEMU" }
        @{ Package='htop';                  Description="Top interactif" }
        @{ Package='vim';                   Description="Éditeur console" }
        @{ Package='ufw';                   Description="Pare-feu simple" }
        @{ Package='whois';                 Description="Client WHOIS" }
        @{ Package='openvpn';               Description="VPN SSL" }
        @{ Package='parted';                Description="Partitionnement disque" }
        @{ Package='git';                   Description="Contrôle de versions" }
        @{ Package='ansible';               Description="Automatisation" }
        @{ Package='python3';               Description="Langage Python 3" }
        @{ Package='python3-pip';           Description="Paquets Python" }
        @{ Package='nodejs';                Description="Runtime JavaScript" }
        @{ Package='npm';                   Description="Paquets Node.js" }
        @{ Package='docker.io';             Description="Moteur Docker" }
        @{ Package='docker-compose-plugin'; Description="Compose v2 plugin" }
        @{ Package='nginx';                 Description="Serveur web" }
        @{ Package='apache2';               Description="Serveur web" }
        @{ Package='certbot';               Description="Let's Encrypt" }
        @{ Package='postgresql';            Description="SGBD PostgreSQL" }
        @{ Package='postgresql-client';     Description="Client psql" }
        @{ Package='mariadb-server';        Description="SGBD MySQL" }
        @{ Package='mysql-client';          Description="Client MySQL" }
    ) | ForEach-Object { [pscustomobject]$_ }

    $selection = $catalog |
        Sort-Object Package |
		Select-Object Package, Description |
        Out-GridView -Title "Sélectionne les packages (Ctrl/Shift pour multi), puis OK" -PassThru

    # Retourne uniquement les noms
    return @($selection | Select-Object -ExpandProperty Package)
}

function Create-VMs {
    $cred = Get-Credentials
    $count = Read-Host "Combien de VM voulez-vous deployer (ex: 1, 2, 5)"
    $ram = Read-Host "RAM par VM (ex: 2, 4)"
    $prefix = Read-Host "Nom de(s) VM(s) (ex: ServeurWEB => format final: TST_ServeurWEB-01)"
	#$IsoPath = "C:\iso"
	
	
    if (-not $count) { $count = 1 }
    if (-not $ram) { $ram = 2 }
    if (-not $prefix) { $prefix = "TST_ENV_" }
	$packageSelected = Select-CloudInitPackages
	$AllPackages = @($packageSelected) |
    Where-Object { $_ -and $_.ToString().Trim() } |
    ForEach-Object { $_.ToString().Trim() } |
    Select-Object -Unique

    # Vérification préalable des noms de VM et fichiers existants
    Write-VerboseLog "[INFO] Vérification des conflits existants..." "Yellow"
    $conflicts = @()

    for ($i = 1; $i -le $count; $i++) {
        $id = "{0:D2}" -f $i
        $VMName = "TST_$prefix-$id"

        # Vérifier VM et fichiers existants sur l'hôte distant
        $conflictInfo = Invoke-Command -ComputerName $RemoteHost -Credential $cred -ArgumentList $VMName, $IsoPath, $VmRoot -ScriptBlock {
            param($Name, $IsoPath, $VmRoot)
            $issues = @()

            # Vérifier VM existante
            if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
                $issues += "VM '$Name' existe déjà"
            }

            # Vérifier ISO existant
            $isoFile = Join-Path $IsoPath "$Name.iso"
            if (Test-Path $isoFile) {
                $issues += "ISO '$Name.iso' existe déjà"
            }

            # Vérifier dossier VM existant
            $vmFolder = Join-Path $VmRoot $Name
            if (Test-Path $vmFolder) {
                $issues += "Dossier '$Name' existe déjà"
            }

            return $issues
        }

        if ($conflictInfo -and $conflictInfo.Count -gt 0) {
            $conflicts += @{VMName = $VMName; Issues = $conflictInfo}
        }
    }

    if ($conflicts.Count -gt 0) {
        Write-Host "`n[ERREUR] Conflits détectés :" -ForegroundColor Red
        foreach ($conflict in $conflicts) {
            Write-Host "`n  VM: $($conflict.VMName)" -ForegroundColor Yellow
            foreach ($issue in $conflict.Issues) {
                Write-Host "    • $issue" -ForegroundColor Red
            }
        }
        Write-Host "`nVeuillez choisir un autre nom ou nettoyer les éléments existants d'abord." -ForegroundColor Yellow
        Pause
        return
    }

    for ($i = 1; $i -le $count; $i++) {
    $id     = "{0:D2}" -f $i
    $VMName = "TST_$prefix-$id"

    if ($NetMode -eq 'STATIC') {
        Write-VerboseLog ("DEBUG Net: Mode={0} IpTemplate='{1}' PoolStart={2}" -f `
            $NetMode, $script:cfg.Network.IpTemplate, $script:cfg.Network.PoolStart) "Yellow"

        if ([string]::IsNullOrWhiteSpace($script:cfg.Network.IpTemplate)) {
            throw "cfg.Network.IpTemplate manquant (ex: '192.168.10.{0}/24')."
        }
        if (-not $script:cfg.Network.PoolStart) { $script:cfg.Network.PoolStart = 200 }

        try {
            # Recharger la config pour avoir les dernières IPs réservées
            $script:cfg = Import-PowerShellDataFile $cfgPath

            $lastOctet = Get-NextAvailableIP -Config $script:cfg
            $IpCidr = ($script:cfg.Network.IpTemplate -f $lastOctet)  # ex: 192.168.10.200/24

            # Réserver l'IP immédiatement avec l'association VM
            Reserve-IP -LastOctet $lastOctet -VmName $VMName -Config $script:cfg -ConfigPath $cfgPath
        }
        catch {
            Write-Error "Erreur lors de l'attribution d'IP pour $VMName : $_"
            continue
        }
    } else {
        $IpCidr = $null
    }
    Write-VerboseLog "[INFO] Création de $VMName (Net=$NetMode IpCidr=$IpCidr)" "Cyan"

    & $PS_CREATE `
        -VMName $VMName `
        -VHDPath $VHDPath `
        -MemoryGB $ram `
        -IsoPath $IsoPath `
        -OscdimgPath $OscdimgPath `
        -RemoteHost $RemoteHost `
        -Credential $cred `
        -VmSwitch $VmSwitch `
        -NetMode $NetMode `
        -IpCidr $IpCidr `
        -Gateway $Gateway `
        -DnsServers $DnsServers `
        -TimeZone $TimeZone `
		-Packages $AllPackages       
}

    # Message de résultat final (toujours affiché)
    Write-ResultLog "`n[SUCCÈS] $count VM(s) créée(s) avec succès !" "Green"

    Invoke-Command -ComputerName $RemoteHost -Credential $cred -ScriptBlock {
        Get-VM | Where-Object { $_.Name -like '*TST*' } | Select-Object Name, State, MemoryAssigned, Uptime, Status
    } | Format-Table -AutoSize

    Pause
}

function Start-AllVMs {
    $cred = Get-Credentials

    # Récupérer les VMs distantes arrêtées (noms seulement)
    $stoppedVMs = Invoke-Command -ComputerName $RemoteHost -Credential $cred -ScriptBlock {
        Get-VM | Where-Object { $_.Name -like 'TST_*' -and $_.State -eq 'Off' } |
        Select-Object -ExpandProperty Name
    }

    if (-not $stoppedVMs -or $stoppedVMs.Count -eq 0) {
        Write-Host "[INFO] Aucune VM [TST_] arrêtée à démarrer." -ForegroundColor Cyan
        pause
        return
    }

    # Sélection via Out-GridView local
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        Write-VerboseLog "`nSélectionnez les VMs à démarrer (CTRL+clic pour sélection multiple), puis cliquez sur OK." "Yellow"
        $selectedNames = $stoppedVMs | Out-GridView -Title "Sélection des VMs à démarrer" -PassThru
    } else {
        Write-VerboseLog "`nEntrez les noms EXACTS des VM(s) à démarrer, séparés par des virgules ou espaces :" "Yellow"
        $userInput = Read-Host "Exemple : TST_VM-01,TST_VM-02"
        $selectedNames = $userInput -split '[,\s]+' | Where-Object { $_ -ne '' }
    }

    if (-not $selectedNames -or $selectedNames.Count -eq 0) {
        Write-Host "[INFO] Aucune VM sélectionnée. Opération annulée." -ForegroundColor Cyan
        pause
        return
    }

    #Envoyer la commande de démarrage à la machine distante
    Invoke-Command -ComputerName $RemoteHost -Credential $cred -ArgumentList @(,$selectedNames) -ScriptBlock {
        param([string[]]$VMNames)

        $i = 0
        $total = $VMNames.Count
        foreach ($name in $VMNames) {
            $i++
            Write-Host "[$i/$total] Démarrage de '$name'..." -NoNewline
            try {
                Start-VM -Name $name -Confirm:$false
                Write-Host " OK" -ForegroundColor Green
            }
            catch {
                Write-Host " ERREUR" -ForegroundColor Red
                Write-Warning "Erreur lors du démarrage de '$name': $_"
            }
        }

        Write-Host "`n[INFO] État final des VMs [TST_]:"
        Get-VM | Where-Object { $_.Name -like 'TST_*' } | Select-Object Name, State | Format-Table -AutoSize
    }

    pause
}


function Stop-AllVMs {
    $cred = Get-Credentials

    # Étape 1 : Récupérer les VMs distantes en cours d'exécution (noms seulement)
    $targetVMs = Invoke-Command -ComputerName $RemoteHost -Credential $cred -ScriptBlock {
        Get-VM | Where-Object { $_.Name -like 'TST_*' -and $_.State -eq 'Running' } |
        Select-Object -ExpandProperty Name
    }

    if (-not $targetVMs -or $targetVMs.Count -eq 0) {
        Write-Host "[INFO] Aucune VM [TST_] en cours d'exécution." -ForegroundColor Cyan
        pause
        return
    }

    # Étape 2 : Sélection via Out-GridView local
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        Write-VerboseLog "`nSélectionnez les VMs à arrêter (CTRL+clic pour sélection multiple), puis cliquez sur OK." "Yellow"
        $selectedNames = $targetVMs | Out-GridView -Title "Sélection des VMs à arrêter" -PassThru
    } else {
        Write-VerboseLog "`nEntrez les noms EXACTS des VM(s) à arrêter, séparés par des virgules ou espaces :" "Yellow"
        $userInput = Read-Host "Exemple : TST_VM-01,TST_VM-02"
        $selectedNames = $userInput -split '[,\s]+' | Where-Object { $_ -ne '' }
    }

    if (-not $selectedNames -or $selectedNames.Count -eq 0) {
        Write-Host "[INFO] Aucune VM sélectionnée. Opération annulée." -ForegroundColor Cyan
        pause
        return
    }

    # Étape 3 : Envoyer la commande d'arrêt à la machine distante
    Invoke-Command -ComputerName $RemoteHost -Credential $cred -ArgumentList @(,$selectedNames) -ScriptBlock {
        param([string[]]$VMNames)

        foreach ($name in $VMNames) {
            try {
				Write-Host "VM '$name' arrêtée" -ForegroundColor Green
                Stop-VM -Name $name -Force -Confirm:$false
            }
            catch {
                Write-Warning "Erreur lors de l'arrêt de '$name': $_"
            }
        }

        Write-Host "`n[INFO] État final des VMs [TST_]:"
        Get-VM | Where-Object { $_.Name -like 'TST_*' } | Select-Object Name, State | Format-Table -AutoSize
    }

    pause
}




function Remove-VMs {
	
	Clear-Host
	$cred = Get-Credentials
	Write-Host "`n=== Suppression d'une ou plusieurs VM(s) TST_ ===" -ForegroundColor Yellow

	# Affichage des VMs disponibles
	$vmList = Invoke-Command -ComputerName $RemoteHost -Credential $cred -ScriptBlock {
		Get-VM | Where-Object { $_.Name -like 'TST_*' } |
			Select-Object Name, State, Uptime, Status
	}

	if (-not $vmList) {
		Write-Host "Aucune VM trouvée dont le nom commence par TST_." -ForegroundColor Red
		Pause
		return
	}

	Write-Host "`n=== Liste des VMs disponibles ===" -ForegroundColor Cyan
	$vmList | Format-Table -AutoSize

	# Tentative d'utilisation d'Out-GridView
	if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
		Write-VerboseLog "`nSélectionnez les VMs à supprimer (CTRL+clic pour sélection multiple), puis cliquez sur OK." "Yellow"
		$selectedVMs = $vmList | Out-GridView -Title "Sélection des VMs à supprimer" -PassThru
	} 

	if (-not $selectedVMs -or $selectedVMs.Count -eq 0) {
		Write-Host "Aucune VM sélectionnée. Opération annulée." -ForegroundColor Yellow
		Pause
		return
	}

	# Confirmation
	Write-Host "`nVous allez supprimer les VM suivantes :"
	$selectedVMs | ForEach-Object { Write-Host " - $($_.Name)" -ForegroundColor Red }

	$confirm = Read-Host "Confirmez-vous la suppression définitive de ces VM(s) ? (oui/non)"
	if ($confirm -ne "oui") {
		Write-Host "Suppression annulée." -ForegroundColor Yellow
		Pause
		return
	}

	$VMNames = $selectedVMs | Select-Object -ExpandProperty Name

	# Suppression distante
	Invoke-Command -ComputerName $RemoteHost -Credential $cred -ArgumentList @(,$VMNames) -ScriptBlock {
		param($names)
		foreach ($vm in $names) 
		{
			$target = Get-VM -Name $vm -ErrorAction SilentlyContinue
			if ($null -eq $target) {
				Write-Warning "VM '$vm' non trouvée. Elle sera ignorée."
				continue
			}

			Write-Host "`nArrêt et suppression de la VM : $vm" -ForegroundColor Cyan
			Stop-VM -Name $vm -Force -TurnOff -ErrorAction SilentlyContinue
			Remove-VM -Name $vm -Force -ErrorAction SilentlyContinue
		}
	}
	
	#Nettoyage iso, vhdx et dossier individuel vms
	Invoke-Command -ComputerName $RemoteHost -Credential $cred -ArgumentList @(,$VMNames) -ScriptBlock {
		param($names)
		$IsoPath         = 'C:\iso'
		$VmPath          = 'E:\BACKUP\VAULTWARDEN_BACKUP\VM TST_'
		
		if (-not (Test-Path -Path 'C:\iso')) { #verif presence répertoire iso
			write-host "Chemin introuvable: $IsoPath"
			return
		}
		if (-not (Test-Path -Path $VmPath)) { #verif presence répertoire vhdx
			write-host "Chemin introuvable: $VmPath"
			return
		}
		foreach ($vm in $names)
		{
			# 1) ISO dans C:\iso qui commencent par $vm
			$isoPattern = "$vm*"
			$isos = Get-ChildItem -LiteralPath $IsoPath -Filter $isoPattern -File -ErrorAction SilentlyContinue
			
			foreach ($f in $isos) 
			{
				Write-Host "`n[$vm] Suppression ISO: $($f.Name)" -ForegroundColor Cyan
				Remove-Item -LiteralPath $f.FullName -Force
			}
			
			# 2) Fichiers sous VmPath qui commencent par $vm
			$filePattern = "$vm*"
			$files = Get-ChildItem -LiteralPath $VmPath -Recurse -File -Filter $filePattern -ErrorAction SilentlyContinue
			foreach ($f in $files) {
				Write-Host "[$vm] Suppression fichier: $($f.FullName)" -ForegroundColor Cyan
				Remove-Item -LiteralPath $f.FullName -Force
			}
			
			# 3) Dossiers à la racine de VmPath qui commencent par $vm
			$dirs = Get-ChildItem -LiteralPath $VmPath -Directory -Filter $filePattern -ErrorAction SilentlyContinue
			foreach ($d in $dirs) {
				Write-Host "[$vm] Suppression dossier: $($d.FullName)" -ForegroundColor Cyan
				Remove-Item -LiteralPath $d.FullName -Recurse -Force -Confirm:$false
			}
		}
	}

	# Libération des IPs pour les VMs supprimées
	if ($NetMode -eq 'STATIC') {
		foreach ($vmName in $VMNames) {
			# Libérer l'IP en utilisant l'association VM → IP
			Release-IP-ByVmName -VmName $vmName -Config $script:cfg -ConfigPath $cfgPath
		}
	}

	Write-ResultLog "`n[SUCCÈS] $($VMNames.Count) VM(s) supprimée(s) avec succès !" "Green"
}




function List-VMs {
    
	$cred = Get-Credentials
    Write-VerboseLog "`n=== Lister les VM(s) ===" "Cyan"
    Write-VerboseLog "1. Lister toutes les VM(s)" "White"
    Write-VerboseLog "2. Lister uniquement les VM(s) TST_ (créées par ce script)" "White"
    $listChoice = Read-Host "Choisissez une option (1 ou 2)"

    $filterScriptBlock = {
    param($mode)
    $vms = Get-VM
    if ($mode -eq 2) {
        $vms = $vms | Where-Object { $_.Name -like 'TST_*' }

        if (-not $vms) {
            Write-Host "Aucune VM correspondant au filtre 'TST_*'." -ForegroundColor Red
        }
    }
    return $vms | Select-Object Name, State, MemoryAssigned, Uptime, Status
}


    if ($listChoice -eq '1' -or $listChoice -eq '2') {
        $vmData = Invoke-Command -ComputerName $RemoteHost -Credential $cred -ArgumentList $listChoice -ScriptBlock $filterScriptBlock
        $vmData | Format-Table -AutoSize
    } else {
        Write-Host "Option invalide. Retour au menu." -ForegroundColor Yellow
    }

    Pause
}

# === MAIN LOOP ===
do {
    Show-Menu
    $choice = Read-Host "Choisissez une option (1-7)"

	switch ($choice) {
		"1" { Create-VMs }
		"2" { Start-AllVMs }
		"3" { Stop-AllVMs }
		"4" { Remove-VMs; pause }
		"5" { List-VMs }
		"6" { Show-OptionsMenu }
		"7" { Write-Host "Au revoir !" ; exit }
		default { Write-Host "Option invalide." -ForegroundColor Red ; Start-Sleep -Seconds 1 }
	}
} while ($true)
