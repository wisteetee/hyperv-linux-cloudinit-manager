<#
========================================================================
 Script : CreateVmRemote.ps1
 Auteur : LEPAPE Remy
 Date   : 03/07/2025
========================================================================
#>

param(
    [Parameter(Mandatory)][string]$IsoPath,
    [Parameter(Mandatory)][string]$TmpDir,
    [Parameter(Mandatory)][string]$OscdimgPath,
    [Parameter(Mandatory)][string]$Hostname,
    [Parameter(Mandatory)][string]$Fqdn,
    [Parameter(Mandatory)][string]$TimeZone,
    [string]$Password = 'Password',
    [string]$Username = 'admin',
    $PasswordHash = $null,
    [string[]]$SshAuthorizedKeys = @(),
    [Parameter(Mandatory)][ValidateSet('DHCP','STATIC')][string]$NetworkMode,
    [string]$IpCidr,
    [string]$Gateway,
    [string[]]$DnsServers = @(),
	[string[]]$Packages = @()
)


$HostnameVM = $Hostname -replace '[^a-z0-9-]', '-' `   # remplace tout ce qui n’est pas a-z, 0-9 ou '_' par '-' (car _ ne passe pas en hostname de VM ubuntu)

# Coupe à 63 caractères (longueur max d’un label) et re-trim si besoin
if ($HostnameVM.Length -gt 63) {
    $HostnameVM = $HostnameVM.Substring(0,63) -replace '-+$',''
}

$AllPackages = @($Packages) | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() } | Select-Object -Unique

# YAML de la section packages
$PackagesYaml = if ($AllPackages.Count -gt 0) {
@"
$(( $AllPackages | ForEach-Object { "  - $_" } ) -join "`n")
"@.Trim()
}


# ---- Contenus UserData/MetaData/NetworkConfig ----
$UserData = @"
#cloud-config
# vim: syntax=yaml


hostname: $HostnameVM
fqdn: $Fqdn
timezone: $TimeZone

growpart:
  mode: auto
  devices: [/]
  ignore_growroot_disabled: false

apt:
#  http_proxy: http://host:port
#  https_proxy: http://host:port
  preserve_sources_list: true

package_update: true
package_upgrade: true
package_reboot_if_required: true
packages:
  - linux-tools-virtual
  - linux-cloud-tools-virtual
  - linux-azure
  - eject
  - console-setup
  - keyboard-configuration
  - unzip
  - net-tools
  - nmap
  - wget
  - curl
  - tree
  $PackagesYaml


keyboard:
  layout: fr
  variant: latin9


users:
  - default
  - name: $Username
    no_user_group: true
    groups: [sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: $Password
    lock_passwd: false
    



disable_root: true    # true: notify default user account / false: allow root ssh login
ssh_pwauth: true      # true: allow login with password; else only with setup pubkey(s)

#ssh_authorized_keys:
#  - ssh-rsa AAAAB... comment


runcmd:
  # remove metadata iso
  - [ sh, -c, "if test -b /dev/cdrom; then eject; fi" ]
  - [ sh, -c, "if test -b /dev/sr0; then eject /dev/sr0; fi" ]
  # disable cloud init on next boot
  - [ sh, -c, touch /etc/cloud/cloud-init.disabled ]
  # set locale
  - [ locale-gen, "fr_FR.UTF-8" ]
  - [ update-locale, "fr_FR.UTF-8" ]
  - [ sh, -c, sed -i 's/XKBLAYOUT=\"\w*"/XKBLAYOUT=\"'fr'\"/g' /etc/default/keyboard ]

write_files:
  - content: |
      #!/bin/bash

      cat /etc/resolv.conf 2>/dev/null | awk '/^nameserver/ { print  }'
    path: /usr/libexec/hypervkvpd/hv_get_dns_info

  - content: |
      #!/bin/bash
      # SPDX-License-Identifier: GPL-2.0
      # Each Distro is expected to implement this script in a distro specific
      # fashion. For instance, on Distros that ship with Network Manager enabled
      # RedHat based systems
      #if_file="/etc/sysconfig/network-scripts/ifcfg-"
      # Debian based systems
      if_file="/etc/network/interfaces.d/*"

      dhcp=`$(grep "dhcp" $if_file 2>/dev/null)

      if [ "$dhcp" != "" ];
      then
      echo "Enabled"
      else
      echo "Disabled"
      fi
    path: /usr/libexec/hypervkvpd/hv_get_dhcp_info


manage_etc_hosts: true
manage_resolv_conf: true

resolv_conf:
  # cloudflare dns, src: https://1.1.1.1/dns/  nameservers: ['1.1.1.1', '1.0.0.1']
  searchdomains:
    - domain.local
  domain: domain.local

power_state:
  mode: reboot
  message: Provisioning finished, will reboot ...
  timeout: 15
"@
# __FIN_UserData_DATA__


# Génère un identifiant unique pour cette VM / seed
$InstanceId = [Guid]::NewGuid().ToString()

$MetaData = @"
dsmode: local
instance-id: $InstanceId
local-hostname: $HostnameVM
"@
# __FIN_MetaData_DATA__

$NetworkConfig = @"
version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses: [$IpCidr]
    gateway4: 192.168.10.254
    nameservers:
      addresses: [192.168.10.10, 1.1.1.1]
"@
# __FIN_Network_CONFIG__

# ---- Prepare temp directory ----
New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null

# écris le contenu dans les differents fichiers en encodage UTF-8 sans BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding($False)
[System.IO.File]::WriteAllText((Join-Path $TmpDir 'user-data'), $UserData, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $TmpDir 'meta-data'), $MetaData, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $TmpDir 'network-config'), $NetworkConfig, $utf8NoBom)

# ---- Construit l'ISO ----
if (-not (Test-Path $OscdimgPath)) {
    throw "oscdimg.exe n'est pas trouvé à ce chemin: $OscdimgPath. Installer Windows ADK Deployment Tools ou mettre à jour le chemin oscdimgPath."
}

$isoDir = Split-Path -Path $IsoPath -Parent
if (-not (Test-Path $isoDir)) { 
New-Item -ItemType Directory -Path $isoDir -Force | Out-Null 
}

if (-not (Test-Path -LiteralPath $OscdimgPath)) {
    throw "oscdimg.exe introuvable: $OscdimgPath"
}

New-Item -ItemType Directory -Path $TmpDir -Force | Out-Null
New-Item -ItemType Directory -Path $IsoPath -Force | Out-Null


$IsoOut = Join-Path $IsoPath "$Hostname.iso"
$null = & $OscdimgPath -d -n -lCIDATA $TmpDir $IsoOut 2>&1
if ($LASTEXITCODE -ne 0) { throw "Échec oscdimg (code $LASTEXITCODE)" }
