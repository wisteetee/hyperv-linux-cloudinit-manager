# 💻 Hyper-V Ubuntu VM Deployer with Cloud-Init

Scripts PowerShell pour provisionner des VMs Linux sur Hyper-V avec cloud-init (datasource NoCloud)

Un outil PowerShell automatisé pour déployer dynamiquement des machines virtuelles Ubuntu sur un hôte **Hyper-V distant**, avec configuration réseau **statique via cloud-init** ou **dynamique DHCP**, selon des paramètres définis dans un fichier de conf.

![HyperV-Linux-Cloudinit-Manager](./img/screen_presentation_readme.png)
---

## 🧭 Objectif

Ce projet permet de :

- Créer automatiquement des VM Ubuntu sur un hôte Hyper-V distant
- Gérer des disques différenciés à partir d'une image parent VHDX
- Générer dynamiquement un ISO `cloud-init` par VM (hostname, IP, etc.)
- Définir une **adresse IP fixe** et un nom d’hôte pour chaque VM
- Démarrer la VM prête à l’emploi, sans intervention manuelle

---

## ⚙️ Fonctionnalités

- ✅ Déploiement distant via **PowerShell Remoting**
- ✅ Génération automatique de fichiers `user-data`, `network-config`, `meta-data`
- ✅ Attribution dynamique d’adresses IP fixes via `stateVM.json`
- ✅ Création d’un ISO `cloud-init` et montage dans la VM
- ✅ Compatibilité **Hyper-V Generation 2** + Ubuntu (cloud-init préinstallé)

---

## 📂 Arborescence simplifiée

/
├── CreateVmRemote.ps1 # Script principal d'orchestration
├── stateVM.json # Fichier d'état : IPs & hostnames par VM
├── tools/
│ └── genisoimage.exe # Utilitaire ISO (nécessaire)
└── README.md # Ce fichier

---

## 📋 Prérequis

- Un hôte Hyper-V (local ou distant) sous Windows Server ou Windows 10/11
- PowerShell Remoting activé sur l’hôte distant
- Un disque VHDX Ubuntu parent avec cloud-init installé : **INSERER ICI PLUS TARD DES CHEMINS POUR TROUVER CES VHDXs**
- L'outils de création d'iso [`oscdimg.exe`], fourni avec le Windows ADK (Assessment and Deployment Kit).(https://learn.microsoft.com/fr-fr/windows-hardware/get-started/adk-install)
- Un switch Hyper-V existant et connecté (ex : `vSwitch-EXT1`)
- Accès admin sur l’hôte distant

---

