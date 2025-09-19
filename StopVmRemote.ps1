<#
========================================================================
 Script : StopVmRemote.ps1
 Auteur : LEPAPE Remy
 Date   : 01/07/2025

 Description :
   Ce script PowerShell permet d'arreter (eteindre) des VMs sur un hôte 
   Hyper-V distant, en filtrant par nom ou prefixe.

 Prerequis :
   - PowerShell Remoting active sur l’hôte distant (voir script powershellRemotingConfAutoInstall.ps1 si besoin)
   - Droits administrateur sur l’hôte distant

 Exemple :
   .\StopVmRemote.ps1 -VMNamePrefix "Test" -RemoteHost "192.168.10.201" -Credential (Get-Credential)
========================================================================
#>

param (
    [string]$VMNamePrefix,
    [string]$RemoteHost,
    [pscredential]$Credential
)

Invoke-Command -ComputerName $RemoteHost -Credential $Credential -ScriptBlock {
    param ($VMNamePrefix)

    $vmsToStop = Get-VM | Where-Object { $_.Name -like "$VMNamePrefix*" -and $_.State -eq 'Running' }

    if ($vmsToStop.Count -eq 0) {
        Write-Host "Aucune VM en cours d'execution correspondant a '$VMNamePrefix'."
        return
    }

    Write-Host "VMs en cours d'arret :"
    foreach ($vm in $vmsToStop) {
        Write-Host " - $($vm.Name)"
        Stop-VM -Name $vm.Name -Force
    }

    Write-Host "`nToutes les VMs correspondantes ont ete arretees."
} -ArgumentList $VMNamePrefix
