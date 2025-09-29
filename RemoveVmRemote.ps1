<#
========================================================================
 Script : RemoveVmRemote.ps1
 Auteur : LEPAPE Remy
 Date   : 26/06/2025

 Description :
   Ce script PowerShell permet de supprimer des VMs Ubuntu creees via
   le script CreateVmRemote.ps1 sur un hôte Hyper-V distant.

   Il liste les VMs correspondant a un nom ou prefixe donne, demande 
   une confirmation explicite a l’utilisateur, puis les supprime 
   (y compris disque differencie et dossier).

 Prerequis :
   - PowerShell Remoting active sur l’hôte distant
   - Compte avec droits Hyper-V sur le serveur distant

 Exemple :
   .\RemoveVmRemote.ps1 -VMNamePrefix "test" -RemoteHost "192.168.10.201" -Credential (Get-Credential)
========================================================================
#>

param (
    [string]$VMNamePrefix,              # Nom complet ou prefixe des VMs a supprimer
    [string]$RemoteHost,                # IP ou nom de l'hôte Hyper-V distant
    [pscredential]$Credential           # Identifiants avec droits Hyper-V
)

Invoke-Command -ComputerName $RemoteHost -Credential $Credential -ScriptBlock {
    param ($VMNamePrefix)

    $VMPath = "E:\BACKUP\VAULTWARDEN_BACKUP"

    # Recupere les VMs qui correspondent exactement ou commencent par le prefixe
    $matchingVMs = Get-VM | Where-Object { $_.Name -like "$VMNamePrefix*" }

    if ($matchingVMs.Count -eq 0) {
        Write-Host "Aucune VM trouvee correspondant a '$VMNamePrefix'."
        return
    }
	
    Write-Host "VMs trouvees correspondant a '$VMNamePrefix' :"
    $matchingVMs | ForEach-Object { Write-Host " - $($_.Name)" }
	
	
    $confirm = Read-Host "`nConfirmer la suppression de ces VMs ? (oui/non)"
    if ($confirm.ToLower() -ne "oui") {
        Write-Host "Suppression annulee par l'utilisateur."
        return
    }

	#Boucle suppression VMs
    foreach ($vm in $matchingVMs) {
        $name = $vm.Name
        $diffDisk = "$VMPath\$name-diff.vhdx"
        $vmFolder = "$VMPath\$name"

        Write-Host "`n Suppression de la VM '$name'..."

        Stop-VM -Name $name -Force -TurnOff -ErrorAction SilentlyContinue
        Remove-VM -Name $name -Force

        if (Test-Path $diffDisk) {
            Remove-Item $diffDisk -Force
            Write-Host " Disque differencie supprime : $diffDisk"
        }

        if (Test-Path $vmFolder) {
            Remove-Item $vmFolder -Recurse -Force
            Write-Host " Dossier de VM supprime : $vmFolder"
        }

        Write-Host (" VM $name supprimee avec succes.")
    }
} -ArgumentList $VMNamePrefix