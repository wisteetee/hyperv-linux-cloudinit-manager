<#
.SYNOPSIS
  Active PowerShell Remoting (HTTP ou HTTPS) sur la machine locale.

.DESCRIPTION
  - Bascule les profils réseaux "Public" en "Privé".
  - Active PowerShell Remoting (Enable-PSRemoting).
  - Si -UseHttps : crée/active un listener WinRM HTTPS (5986) avec certificat (auto-signé si besoin) + ouvre le pare-feu 5986.
  - Sinon (HTTP/5985) : n'ajoute TrustedHosts que si la machine N'EST PAS jointe au domaine (workgroup).
  - Test final via Test-WSMan (selon HTTP/HTTPS).

.NOTES
  À exécuter en **administrateur**.
#>

param(
  [string]$RemoteHost = "192.168.10.201",
  [switch]$UseHttps,                      # Recommandé en prod
  [string]$HttpsCertificateThumbprint,    # Si tu as déjà un cert serveur (LocalMachine\My)
  [string]$HttpsCertDnsName               # Si non fourni, on génère un auto-signé pour ce DNS (par défaut: FQDN local)
)

Write-Host "`n--- Activation de PowerShell Remoting ---`n" -ForegroundColor Cyan

# Étape 0 : helpers
function Add-TrustedHostUnique {
  param([Parameter(Mandatory)][string]$HostToAdd)
  $path = 'WSMan:\localhost\Client\TrustedHosts'
  $current = (Get-Item -Path $path -ErrorAction SilentlyContinue).Value
  $list = @()
  if ($current) { $list += ($current -split ',') }
  $list += $HostToAdd
  $list = $list | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique
  Set-Item -Path $path -Value ($list -join ',') -Force
  Get-Item -Path $path
}

function Ensure-WinRM-HTTPS {
  param(
    [string]$Thumbprint,
    [string]$DnsName
  )
  # 1) Certificat
  if (-not $Thumbprint) {
    if (-not $DnsName -or [string]::IsNullOrWhiteSpace($DnsName)) {
      # FQDN local si possible, sinon nom NetBIOS
      try {
        $DnsName = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
      } catch {
        $DnsName = $env:COMPUTERNAME
      }
    }
    Write-Host "Création d'un certificat auto-signé pour $DnsName..." -ForegroundColor Yellow
    $cert = New-SelfSignedCertificate -DnsName $DnsName `
      -CertStoreLocation 'Cert:\LocalMachine\My' `
      -KeyLength 2048 -HashAlgorithm sha256 `
      -NotAfter (Get-Date).AddYears(3) `
      -FriendlyName "WinRM HTTPS ($DnsName)"
    $Thumbprint = $cert.Thumbprint
  } else {
    $cert = Get-Item -Path "Cert:\LocalMachine\My\$Thumbprint" -ErrorAction Stop
  }

  # 2) Listener HTTPS
  $hasHttps = (Get-ChildItem WSMan:\Localhost\Listener -ErrorAction SilentlyContinue |
               Where-Object { $_.Keys -match 'Transport=HTTPS' })
  if (-not $hasHttps) {
    Write-Host "Création du listener WinRM HTTPS (5986)..." -ForegroundColor Yellow
    New-Item -Path WSMan:\Localhost\Listener `
      -Transport HTTPS -Address * -CertificateThumbprint $Thumbprint | Out-Null
  } else {
    Write-Host "Listener WinRM HTTPS déjà présent." -ForegroundColor Green
  }

  # 3) Pare-feu 5986
  $rule = Get-NetFirewallRule -DisplayName 'WinRM HTTPS Inbound' -ErrorAction SilentlyContinue
  if (-not $rule) {
    New-NetFirewallRule -Name 'WinRM_HTTPS' -DisplayName 'WinRM HTTPS Inbound' `
      -Protocol TCP -LocalPort 5986 -Direction Inbound -Action Allow | Out-Null
    Write-Host "Règle pare-feu 5986 ajoutée." -ForegroundColor Green
  } else {
    Enable-NetFirewallRule -DisplayName 'WinRM HTTPS Inbound' -ErrorAction SilentlyContinue
    Write-Host "Règle pare-feu 5986 activée." -ForegroundColor Green
  }

  return $Thumbprint
}

# Étape 1 : Mettre les interfaces Public -> Privé
$publicProfiles = Get-NetConnectionProfile | Where-Object { $_.NetworkCategory -eq 'Public' }
if ($publicProfiles.Count -eq 0) {
  Write-Host "Aucune interface en mode Public détectée." -ForegroundColor Green
} else {
  foreach ($profile in $publicProfiles) {
    Write-Host "Changement de l'interface '$($profile.InterfaceAlias)' en 'Privé'..."
    try {
      Set-NetConnectionProfile -InterfaceIndex $profile.InterfaceIndex -NetworkCategory Private -ErrorAction Stop
      Write-Host "OK." -ForegroundColor Green
    } catch {
      Write-Host "Échec : $($_.Exception.Message)" -ForegroundColor Red
    }
  }
}

# Étape 2 : Activer PowerShell Remoting (HTTP par défaut)
Write-Host "`nActivation de PowerShell Remoting..." -ForegroundColor Cyan
try {
  Enable-PSRemoting -SkipNetworkProfileCheck -Force -ErrorAction Stop
  Write-Host "Enable-PSRemoting effectué." -ForegroundColor Green
} catch {
  Write-Host "Échec de l’activation : $($_.Exception.Message)" -ForegroundColor Red
}

# Étape 3 : HTTPS recommandé en prod
if ($UseHttps) {
  Write-Host "`nConfiguration du listener HTTPS (recommandé en production)..." -ForegroundColor Cyan
  try {
    $tp = Ensure-WinRM-HTTPS -Thumbprint $HttpsCertificateThumbprint -DnsName $HttpsCertDnsName
    Write-Host "Listener HTTPS opérationnel. Cert thumbprint: $tp" -ForegroundColor Green
  } catch {
    Write-Host "Échec config HTTPS : $($_.Exception.Message)" -ForegroundColor Red
  }
} else {
  # Étape 3 bis : HTTP + TrustedHosts UNIQUEMENT en workgroup
  $isDomainJoined = (Get-CimInstance Win32_ComputerSystem).PartOfDomain
  if (-not $isDomainJoined) {
    Write-Host "`nWorkgroup détecté : ajout de l'hôte distant aux TrustedHosts (HTTP)..." -ForegroundColor Yellow
    try {
      Add-TrustedHostUnique -HostToAdd $RemoteHost | Out-Null
      Write-Host "TrustedHosts mis à jour." -ForegroundColor Green
    } catch {
      Write-Host "Échec mise à jour TrustedHosts : $($_.Exception.Message)" -ForegroundColor Red
    }
  } else {
    Write-Host "Machine jointe au domaine : Kerberos gérera la confiance (pas de TrustedHosts nécessaire)." -ForegroundColor Green
  }
}

# Étape 4 : Test final local
Write-Host "`nVérification finale avec Test-WSMan (local)..." -ForegroundColor Cyan
try {
  if ($UseHttps) { Test-WSMan -UseSSL localhost } else { Test-WSMan localhost }
  Write-Host "WinRM répond correctement sur localhost." -ForegroundColor Green
} catch {
  Write-Host "Test échoué : WinRM ne répond pas." -ForegroundColor Red

# Ajout préconfiguration nécessaire
# Installation module TUN.CredentialManager pour gestion informations de connexion serveur distant.

# Supprimer les autres modules potentiellement conflictuels
Get-Module PSCredentialManager, CredentialManager -ErrorAction SilentlyContinue | Remove-Module -Force

# Importer explicitement TUN.CredentialManager
if (-not (Get-Module -Name TUN.CredentialManager -ListAvailable)) {
	Write-Host "Installation de TUN.CredentialManager..." -ForegroundColor Yellow
	Install-Module TUN.CredentialManager -Force -AllowClobber -Scope CurrentUser
}
Import-Module TUN.CredentialManager -Force
Write-Host "✓ Module TUN.CredentialManager chargé" -ForegroundColor Green


Write-Host "`n--- Fin du script ---`n" -ForegroundColor Cyan

# Exemples :
# HTTP (workgroup) : Invoke-Command -ComputerName $RemoteHost -Credential (Get-Credential) -ScriptBlock { hostname }
# HTTPS : Invoke-Command -ComputerName $RemoteHost -UseSSL -Credential (Get-Credential) -ScriptBlock { hostname }
