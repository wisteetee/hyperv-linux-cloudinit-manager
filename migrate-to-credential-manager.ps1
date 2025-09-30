<#
.SYNOPSIS
Script de migration vers Windows Credential Manager

.DESCRIPTION
Ce script migre les identifiants stockés dans creds.xml vers Windows Credential Manager
et nettoie les anciens fichiers de configuration.

.AUTHOR
Rémy LEPAPE

.DATE
2025-01-10
#>

param(
    [switch]$WhatIf,
    [switch]$Force
)

$TF_DIR = $PSScriptRoot
$cfgPath = Join-Path $TF_DIR 'config.psd1'

Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  MIGRATION VERS WINDOWS CREDENTIAL MANAGER" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Vérifier la configuration
if (-not (Test-Path $cfgPath)) {
    throw "Config manquante: $cfgPath"
}

$cfg = Import-PowerShellDataFile $cfgPath

# Chercher l'ancien fichier creds.xml
$oldCredFile = $null
$possiblePaths = @(
    (Join-Path $TF_DIR 'creds.xml'),
    (Join-Path $TF_DIR '..\..\..\0. Mise en oeuvre\ServeurDistantPowershell\creds.xml')
)

foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
        $oldCredFile = $path
        break
    }
}

if ($oldCredFile) {
    Write-Host "`n🔍 Ancien fichier trouvé: $oldCredFile" -ForegroundColor Yellow

    try {
        $oldCred = Import-Clixml -Path $oldCredFile
        $remoteHost = if ($cfg.ContainsKey('RemoteHost')) { $cfg.RemoteHost } else { "192.168.10.201" }

        Write-Host "📋 Informations trouvées:" -ForegroundColor Cyan
        Write-Host "   Utilisateur: $($oldCred.UserName)"
        Write-Host "   Serveur: $remoteHost"

        if ($WhatIf) {
            Write-Host "`n[SIMULATION] Migration qui serait effectuée:" -ForegroundColor Yellow
            Write-Host "  1. Installation module CredentialManager"
            Write-Host "  2. Création target: HyperV-Host-$remoteHost"
            Write-Host "  3. Sauvegarde de $oldCredFile"
            Write-Host "  4. Suppression de $oldCredFile"
            return
        }

        $response = Read-Host "`nMigrer ces identifiants vers Credential Manager ? (o/n)"
        if ($response -eq 'o' -or $response -eq 'oui' -or $response -eq 'O') {

            # Installation du module si nécessaire
            if (-not (Get-Module -ListAvailable CredentialManager)) {
                Write-Host "📦 Installation du module CredentialManager..." -ForegroundColor Yellow
                Install-Module CredentialManager -Scope CurrentUser -Force -AllowClobber
            }

            Import-Module CredentialManager -Force

            # Migration
            $targetName = "HyperV-Host-$remoteHost"

            # Vérifier si le target existe déjà
            $existing = Get-StoredCredential -Target $targetName -ErrorAction SilentlyContinue
            if ($existing -and -not $Force) {
                Write-Host "⚠️ Un identifiant existe déjà pour $remoteHost" -ForegroundColor Yellow
                $overwrite = Read-Host "Écraser ? (o/n)"
                if ($overwrite -ne 'o' -and $overwrite -ne 'oui' -and $overwrite -ne 'O') {
                    Write-Host "❌ Migration annulée" -ForegroundColor Red
                    return
                }
                Remove-StoredCredential -Target $targetName
            }

            # Créer le nouvel identifiant
            New-StoredCredential -Target $targetName `
                                -UserName $oldCred.UserName `
                                -Password $oldCred.Password `
                                -Type Generic `
                                -Comment "Migré depuis creds.xml le $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

            Write-Host "✅ Identifiants migrés avec succès vers Credential Manager" -ForegroundColor Green

            # Sauvegarde de l'ancien fichier
            $backupPath = "$oldCredFile.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
            Copy-Item $oldCredFile $backupPath
            Write-Host "💾 Ancien fichier sauvegardé: $backupPath" -ForegroundColor Cyan

            # Suppression de l'ancien fichier
            Remove-Item $oldCredFile -Force
            Write-Host "🗑️ Ancien fichier supprimé: $oldCredFile" -ForegroundColor Green

            # Test de la nouvelle connexion
            Write-Host "`n🔧 Test de la nouvelle configuration..." -ForegroundColor Yellow
            try {
                $newCred = Get-StoredCredential -Target $targetName
                $testResult = Test-Connection -ComputerName $remoteHost -Count 1 -Quiet
                if ($testResult) {
                    Write-Host "✅ Test de connexion réussi" -ForegroundColor Green
                } else {
                    Write-Host "⚠️ Ping échoué, mais identifiants stockés" -ForegroundColor Yellow
                }
            }
            catch {
                Write-Host "❌ Erreur lors du test: $_" -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Host "❌ Erreur lors de la lecture de l'ancien fichier: $_" -ForegroundColor Red
    }
} else {
    Write-Host "`n✅ Aucun ancien fichier creds.xml trouvé" -ForegroundColor Green
}

# Vérifier l'état actuel
$hyperVHosts = Get-StoredCredential | Where-Object { $_.TargetName -like "HyperV-Host-*" }
if ($hyperVHosts.Count -gt 0) {
    Write-Host "`n📊 État actuel du Credential Manager:" -ForegroundColor Cyan
    foreach ($host in $hyperVHosts) {
        $ip = ($host.TargetName -split '-')[-1]
        Write-Host "   • Serveur: $ip (Utilisateur: $($host.UserName))" -ForegroundColor Green
    }
} else {
    Write-Host "`n⚠️ Aucun serveur Hyper-V configuré dans Credential Manager" -ForegroundColor Yellow
    Write-Host "Utilisez le nouveau script avec l'option 6 > 3 pour configurer un serveur" -ForegroundColor Cyan
}

Write-Host "`n✅ Migration terminée !" -ForegroundColor Green
Write-Host "Vous pouvez maintenant utiliser deploy_vms_remote.ps1 normalement" -ForegroundColor Cyan