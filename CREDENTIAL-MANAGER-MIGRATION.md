# 🔐 Migration vers Windows Credential Manager

## 📋 **Vue d'ensemble**

Cette version introduit l'utilisation de **Windows Credential Manager** pour la gestion sécurisée des identifiants Hyper-V, remplaçant l'ancien système de fichiers XML non sécurisé.

## 🚀 **Nouveautés**

### ✅ **Sécurité renforcée**
- **Chiffrement DPAPI** : Identifiants chiffrés par l'API Windows
- **Intégration système** : Utilise le coffre-fort Windows natif
- **Pas de fichiers sensibles** : Plus de `creds.xml` en clair

### ✅ **Gestion multi-serveurs**
- **Support de plusieurs serveurs** Hyper-V simultanément
- **Sélection automatique** si un seul serveur configuré
- **Changement facile** de serveur via le menu Options

### ✅ **Interface améliorée**
- **Menu Options étendu** (6 > 3) pour gérer les serveurs
- **Tests de connexion** intégrés
- **Migration automatique** depuis l'ancien système

## 🔄 **Migration depuis l'ancienne version**

### **Option 1 : Migration automatique**
```powershell
# Lance le script de migration
.\migrate-to-credential-manager.ps1

# Test seulement (simulation)
.\migrate-to-credential-manager.ps1 -WhatIf

# Forcer l'écrasement
.\migrate-to-credential-manager.ps1 -Force
```

### **Option 2 : Configuration manuelle**
```powershell
# Lance le script principal
.\deploy_vms_remote.ps1

# Lors du premier lancement :
# 1. Détection automatique de l'absence de serveur
# 2. Proposition de configurer le serveur depuis config.psd1
# 3. Saisie des identifiants sécurisée
```

## 🎯 **Utilisation**

### **Première utilisation**
1. **Lancement** : `.\deploy_vms_remote.ps1`
2. **Configuration** : Le script détecte automatiquement l'absence de serveur
3. **Identifiants** : Saisie sécurisée via `Get-Credential`
4. **Stockage** : Automatique dans Windows Credential Manager

### **Gestion des serveurs**
- **Menu principal** → **6. Options** → **3. Gérer les serveurs Hyper-V**
- **Ajouter un serveur** : Option 1
- **Tester les connexions** : Option 2
- **Supprimer un serveur** : Option 3
- **Changer de serveur** : Option 4

### **Multi-serveurs**
```powershell
# Exemple de configuration
HyperV-Host-192.168.10.201  # Serveur de développement
HyperV-Host-192.168.20.201  # Serveur de production
HyperV-Host-192.168.30.201  # Serveur de test
```

## 🔧 **Détails techniques**

### **Stockage des identifiants**
```
Target: "HyperV-Host-192.168.10.201"
Type: Generic
UserName: "DOMAIN\username"
Password: [Chiffré par DPAPI]
Comment: "Serveur Hyper-V - Gestion VMs"
```

### **Emplacements dans Windows**
- **Credential Manager** : `control.exe /name Microsoft.CredentialManager`
- **Registre** : `HKEY_CURRENT_USER\Software\Microsoft\Credentials`
- **Fichiers** : `%LOCALAPPDATA%\Microsoft\Credentials\`

### **Module PowerShell requis**
```powershell
# Installation automatique lors du premier usage
Install-Module CredentialManager -Scope CurrentUser -Force
```

## 🛡️ **Sécurité**

### **Avantages vs ancien système**
| **Aspect** | **Ancien (creds.xml)** | **Nouveau (Credential Manager)** |
|------------|------------------------|----------------------------------|
| **Chiffrement** | ⚠️ Utilisateur spécifique | ✅ DPAPI Windows intégré |
| **Visibilité** | ❌ Fichier XML lisible | ✅ Invisible dans l'explorateur |
| **Audit** | ❌ Aucune traçabilité | ✅ Logs Windows intégrés |
| **Partage** | ❌ Fichier copiable | ✅ Lié à l'utilisateur/machine |

### **Limitations**
- **Utilisateur spécifique** : Chaque utilisateur doit configurer ses propres identifiants
- **Machine spécifique** : Non transférable entre machines
- **Pas de partage d'équipe** : Solution individuelle

## 📂 **Fichiers modifiés**

### **Principaux changements**
- `deploy_vms_remote.ps1` : Fonctions Credential Manager ajoutées
- `config.psd1` : RemoteHost et CredFile commentés (obsolètes)
- `migrate-to-credential-manager.ps1` : Script de migration (nouveau)

### **Rétrocompatibilité**
- **config.psd1** : Ancienne configuration conservée en commentaire
- **Migration** : Détection automatique de l'ancien système
- **Transition** : Douce et guidée

## ❓ **FAQ**

### **Q: Que faire si j'ai plusieurs machines ?**
**R:** Chaque machine nécessite sa propre configuration via Credential Manager.

### **Q: Comment sauvegarder mes identifiants ?**
**R:** Utilisez l'export Windows ou notez vos identifiants séparément.

### **Q: Puis-je revenir à l'ancien système ?**
**R:** Oui, en restaurant le fichier `creds.xml.backup` et en revertant la branche DEV.

### **Q: Le module CredentialManager est-il sûr ?**
**R:** Oui, c'est un module officiel Microsoft avec 2M+ de téléchargements.

## 🚨 **En cas de problème**

### **Erreur "Module CredentialManager introuvable"**
```powershell
Install-Module CredentialManager -Scope CurrentUser -Force
Import-Module CredentialManager
```

### **Erreur "Aucun serveur configuré"**
```powershell
# Via le menu
.\deploy_vms_remote.ps1
# → 6. Options → 3. Gérer les serveurs → 1. Ajouter

# Ou via migration
.\migrate-to-credential-manager.ps1
```

### **Identifiants corrompus**
```powershell
# Supprimer et recréer
Remove-StoredCredential -Target "HyperV-Host-192.168.10.201"
# Puis relancer le script pour reconfigurer
```

---
**📅 Version :** DEVAI
**🔄 Dernière mise à jour :** 2025-01-10
**👨‍💻 Auteur :** Rémy LEPAPE