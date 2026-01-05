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

#Appel fct de logs
. "$PSScriptRoot\logging.ps1"
Write-Log "===== DÉMARRAGE DU SCRIPT deploy_vms_remote.ps1 ====="
try {
	
	$TF_DIR  = $PSScriptRoot
	$cfgPath = Join-Path $TF_DIR 'config.psd1'
	if (-not (Test-Path $cfgPath)) { throw "Config manquante: $cfgPath" }
	$cfg = Import-PowerShellDataFile $cfgPath
	$script:cfg = $cfg
	
	# si l’utilisateur n’a pas fourni ce paramètre à l’appel, alors prends la valeur depuis la conf.
	if (-not $PSBoundParameters.ContainsKey('RemoteHost')) { $RemoteHost  = $cfg.RemoteHost }
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
	$CredFile  = Join-Path $BaseDir $cfg.Scripts.CredFile
	$targetCred = "$RemoteHost"+"HyperV"
	
	# Fonction de récupération du fichier contenant les identifiants de connection ou création/complétion si n'existe pas déjà
	function Get-Credentials {
	  $script:cred = Get-StoredCredential -Target $targetCred
	  return $script:cred  # Retourner la valeur
	}
	
	# Installation module TUN.CredentialManager pour gestion informations de connexion serveur distant.
	function Ensure-CredentialModule {
		# Supprimer les autres modules potentiellement conflictuels
		Get-Module PSCredentialManager, CredentialManager -ErrorAction SilentlyContinue | Remove-Module -Force
	
		# Importer explicitement TUN.CredentialManager
		if (-not (Get-Module -Name TUN.CredentialManager -ListAvailable)) {
			Write-Host "Installation de TUN.CredentialManager..." -ForegroundColor Yellow
			Install-Module TUN.CredentialManager -Force -AllowClobber -Scope CurrentUser
		}
		Import-Module TUN.CredentialManager -Force
		Write-Host "✓ Module TUN.CredentialManager chargé" -ForegroundColor Green
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
	
	function Show-OptionsMenu {
	    do {
	        Clear-Host
	        $currentVerbose = $script:cfg.Options.VerboseMode
	        $verboseStatus = if ($currentVerbose) { "ACTIVÉ" } else { "DÉSACTIVÉ" }
	
	        Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
	        Write-Host "║                         OPTIONS                          ║" -ForegroundColor Cyan
	        Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
	        Write-Host "║                                                          ║"
	        Write-Host ("║ Mode Verbose : {0,-36}      ║" -f $verboseStatus)
	        Write-Host "║                                                          ║"
	        Write-Host "║  1. Activer le mode Verbose                              ║"
	        Write-Host "║  2. Désactiver le mode Verbose                           ║"
			Write-Host "║  3. Sélectionner les informations de connexion par défaut║"
			Write-Host "║  4. Définir de nouvelles informations de connexion       ║"
	        Write-Host "║  5. Retour au menu principal                             ║"
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
	                #ajouter la selection des creds souhaités
					Write-Host "Voilà les credentials existants:" -ForegroundColor Blue
					#utiisation de cmdkey car 
					$hyperVCreds = cmdkey /list | Select-String "Cible :" | ForEach-Object {
						if ($_.Line -match "target=(.+)") {
							$matches[1]
						}
					} | Where-Object { $_ -like "*HyperV" }
					if ($hyperVCreds) {
						$hyperVCreds | ForEach-Object {
							Write-Host "  - $_" -ForegroundColor Gray
						}
					} else {
						Write-Host "  Aucun credential se terminant par 'HyperV' trouvé" -ForegroundColor Red
					}
					pause
	            }
				"4" {
					Write-Host "Entrez vos identifiants de connexion au serveur distant $RemoteHost" 
	                $choice = Get-Credential
					New-StoredCredential -Target $targetCred -UserName $choice.UserName -SecurePassword $choice.Password -Type Generic -Persist LocalMachine | Out-Null
					
					$script:cred = Get-StoredCredential -Target $targetCred
					Write-Host "✓ Username récupéré: $($cred.UserName) et mdp: $($cred.GetNetworkCredential().Password)" -ForegroundColor Green
					#$choice = Read-Host "Entrez vos identifiants de connexion au serveur distant $RemoteHost"
					pause
	            }
	            "5" {
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
		
	    Write-VerboseLog "[DEBUG] Test de connexion vers $RemoteHost..." "Yellow"
	    $serverReachable = Test-Connection -ComputerName $RemoteHost -Count 1 -Quiet
	    $status = if ($serverReachable) { "Connecte" } else { "Non disponible" }
	    Write-Host "╔══════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
	    Write-Host "║               Hyper-V Ubuntu VM Manager                  ║" -ForegroundColor Cyan
	    Write-Host "╠══════════════════════════════════════════════════════════╣" -ForegroundColor Cyan
	    Write-Host ("║ Date : {0,-20} Heure : {1,-15}      ║" -f (Get-Date -Format 'dd/MM/yyyy'), (Get-Date -Format 'HH:mm:ss'))
	    Write-Host ("║ Serveur Distant : {0,-36}   ║" -f "$status ($RemoteHost)")
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
	    Write-Host "1. Lister toutes les VM(s)"
	    Write-Host "2. Lister uniquement les VM(s) TST_ (créées par ce script)"
	    $listChoice = Read-Host "Choisissez une option (1 ou 2)"
	
	    $filterScriptBlock = {
			param($mode)
			$vms = Get-VM
			if ($mode -eq 2) 
			{
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
}
finally {
    Write-Log "===== FIN DU SCRIPT deploy_vms_remote.ps1 ====="
    Flush-Logs
}
