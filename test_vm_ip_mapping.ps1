# Script de test pour le système intégré de gestion VM-IP
# =========================================================

$TF_DIR  = $PSScriptRoot
$cfgPath = Join-Path $TF_DIR 'config.psd1'

Write-Host "=== Test du système intégré VM-IP Mapping ===" -ForegroundColor Cyan
Write-Host "Chargement de la configuration depuis: $cfgPath" -ForegroundColor Yellow

# Charger la configuration
if (-not (Test-Path $cfgPath)) {
    Write-Error "Config manquante: $cfgPath"
    exit 1
}

$cfg = Import-PowerShellDataFile $cfgPath

# Inclure les fonctions (copie du code dans deploy_vms_remote.ps1)
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

        Write-Host "[INFO] IP .$LastOctet réservée pour $VmName" -ForegroundColor Green
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

        Write-Host "[INFO] IP .$ipOctet libérée pour $VmName" -ForegroundColor Green
    } else {
        Write-Host "[WARNING] Aucune association IP trouvée pour $VmName" -ForegroundColor Yellow
    }
}

# Tests
Write-Host "`n1. État initial:" -ForegroundColor Yellow
Write-Host "   IPs utilisées: [$($cfg.Network.UsedIPs -join ', ')]"
Write-Host "   VM Mapping: $($cfg.Network.VmIpMapping.Count) entrées"

Write-Host "`n2. Test: Créer 3 VMs (TST_TEST-01, TST_TEST-02, TST_TEST-03)" -ForegroundColor Yellow
$testVMs = @("TST_TEST-01", "TST_TEST-02", "TST_TEST-03")

foreach ($vmName in $testVMs) {
    try {
        $ip = Get-NextAvailableIP -Config $cfg
        Write-Host "   VM '$vmName' → IP .$ip"
        Reserve-IP -LastOctet $ip -VmName $vmName -Config $cfg -ConfigPath $cfgPath
    }
    catch {
        Write-Error "   Erreur pour $vmName : $_"
    }
}

Write-Host "`n3. État après création:" -ForegroundColor Yellow
# Recharger la config pour voir les changements
$cfg = Import-PowerShellDataFile $cfgPath
Write-Host "   IPs utilisées: [$($cfg.Network.UsedIPs -join ', ')]"
Write-Host "   VM Mapping:"
foreach ($vm in $cfg.Network.VmIpMapping.Keys) {
    Write-Host "     $vm → .$($cfg.Network.VmIpMapping[$vm])"
}

Write-Host "`n4. Test: Supprimer TST_TEST-02" -ForegroundColor Yellow
Release-IP-ByVmName -VmName "TST_TEST-02" -Config $cfg -ConfigPath $cfgPath

Write-Host "`n5. État après suppression:" -ForegroundColor Yellow
# Recharger la config une dernière fois
$cfg = Import-PowerShellDataFile $cfgPath
Write-Host "   IPs utilisées: [$($cfg.Network.UsedIPs -join ', ')]"
Write-Host "   VM Mapping:"
foreach ($vm in $cfg.Network.VmIpMapping.Keys) {
    Write-Host "     $vm → .$($cfg.Network.VmIpMapping[$vm])"
}

Write-Host "`n6. Test: Créer une nouvelle VM (devrait reprendre l'IP libérée)" -ForegroundColor Yellow
try {
    $ip = Get-NextAvailableIP -Config $cfg
    Write-Host "   Prochaine IP disponible: .$ip (devrait être celle libérée)" -ForegroundColor Green
    Reserve-IP -LastOctet $ip -VmName "TST_NEW-01" -Config $cfg -ConfigPath $cfgPath
}
catch {
    Write-Error "   Erreur: $_"
}

Write-Host "`n=== Test terminé ===" -ForegroundColor Cyan