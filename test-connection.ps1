# Script de test de connexion PowerShell Remoting
# Test simple pour vérifier la connectivité

$ServerIP = "192.168.10.201"
$Username = "remy.lepape@aurera.fr"
$Password = "Teeworld54*"

Write-Host "=== TEST DE CONNEXION POWERSHELL REMOTING ===" -ForegroundColor Cyan
Write-Host "Serveur: $ServerIP" -ForegroundColor White
Write-Host "Utilisateur: $Username" -ForegroundColor White

# Créer l'objet PSCredential
$SecurePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($Username, $SecurePassword)

# Test 1: Ping
Write-Host "`n1. Test de connectivité réseau..." -NoNewline
if (Test-Connection -ComputerName $ServerIP -Count 1 -Quiet) {
    Write-Host " ✅ OK" -ForegroundColor Green
} else {
    Write-Host " ❌ ÉCHEC" -ForegroundColor Red
    Write-Host "Le serveur $ServerIP n'est pas joignable" -ForegroundColor Yellow
    exit 1
}

# Test 2: PowerShell Remoting simple
Write-Host "2. Test PowerShell Remoting basique..." -NoNewline
try {
    $result = Invoke-Command -ComputerName $ServerIP -Credential $Credential -ScriptBlock {
        $env:COMPUTERNAME
    } -ErrorAction Stop

    Write-Host " ✅ OK" -ForegroundColor Green
    Write-Host "   Nom distant: $result" -ForegroundColor Cyan
}
catch {
    Write-Host " ❌ ÉCHEC" -ForegroundColor Red
    Write-Host "   Erreur: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "`n--- DÉTAILS DE L'ERREUR ---" -ForegroundColor Yellow
    Write-Host $_.Exception.GetType().FullName -ForegroundColor Gray
    Write-Host $_.Exception.InnerException -ForegroundColor Gray
}

# Test 3: Information système
Write-Host "3. Test récupération infos système..." -NoNewline
try {
    $sysInfo = Invoke-Command -ComputerName $ServerIP -Credential $Credential -ScriptBlock {
        Get-ComputerInfo | Select-Object WindowsProductName, TotalPhysicalMemory, CsProcessors
    } -ErrorAction Stop

    Write-Host " ✅ OK" -ForegroundColor Green
    Write-Host "   OS: $($sysInfo.WindowsProductName)" -ForegroundColor Cyan
    Write-Host "   RAM: $([math]::Round($sysInfo.TotalPhysicalMemory/1GB, 1)) GB" -ForegroundColor Cyan
    Write-Host "   CPU: $($sysInfo.CsProcessors.Count) processeur(s)" -ForegroundColor Cyan
}
catch {
    Write-Host " ❌ ÉCHEC" -ForegroundColor Red
    Write-Host "   Erreur: $($_.Exception.Message)" -ForegroundColor Yellow
}

# Test 4: Commandes Hyper-V
Write-Host "4. Test commandes Hyper-V..." -NoNewline
try {
    $hyperVInfo = Invoke-Command -ComputerName $ServerIP -Credential $Credential -ScriptBlock {
        Get-VMHost | Select-Object Name, MemoryCapacity, LogicalProcessorCount
    } -ErrorAction Stop

    Write-Host " ✅ OK" -ForegroundColor Green
    Write-Host "   Hôte Hyper-V: $($hyperVInfo.Name)" -ForegroundColor Cyan
    Write-Host "   Capacité mémoire: $([math]::Round($hyperVInfo.MemoryCapacity/1GB, 1)) GB" -ForegroundColor Cyan
    Write-Host "   Processeurs logiques: $($hyperVInfo.LogicalProcessorCount)" -ForegroundColor Cyan
}
catch {
    Write-Host " ❌ ÉCHEC" -ForegroundColor Red
    Write-Host "   Erreur: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host "`n=== FIN DES TESTS ===" -ForegroundColor Cyan