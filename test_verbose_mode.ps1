# Script de test du mode Verbose
# ==============================

$TF_DIR  = $PSScriptRoot
$cfgPath = Join-Path $TF_DIR 'config.psd1'

Write-Host "=== Test du mode Verbose ===" -ForegroundColor Cyan

# Charger la configuration
if (-not (Test-Path $cfgPath)) {
    Write-Error "Config manquante: $cfgPath"
    exit 1
}

$cfg = Import-PowerShellDataFile $cfgPath
$script:cfg = $cfg

# Inclure les fonctions de test
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

# Test
Write-Host "`nÉtat actuel du mode Verbose: $($script:cfg.Options.VerboseMode)" -ForegroundColor Yellow

Write-Host "`nTest des messages:"
Write-VerboseLog "[VERBOSE] Ce message ne s'affiche qu'en mode verbose" "Green"
Write-ResultLog "[RÉSULTAT] Ce message s'affiche toujours" "Cyan"

Write-Host "`nTest terminé !" -ForegroundColor Cyan