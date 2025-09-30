@{
  # RemoteHost = '192.168.10.201'  # OBSOLÈTE : Désormais géré par Windows Credential Manager

  Paths = @{
    ParentVhdx   = 'E:\BACKUP\VAULTWARDEN_BACKUP\VM TST_\VHDX PARENT\CloudVMUbuntu.vhdx'
    VmRoot       = 'E:\BACKUP\VAULTWARDEN_BACKUP\VM TST_'
    IsoPath      = 'C:\iso'
    OscdimgPath  = 'C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe'
  }

  Network = @{
    Mode        = 'STATIC'  # ou 'DHCP' STATIC
    Gateway     = '192.168.10.254'
    DnsServers  = @('192.168.10.10','1.1.1.1')
    TimeZone    = 'UTC'
	PoolStart  = 200                       # 1ere IP: .200
	PoolEnd    = 250                       # Derniere IP: .250
	IpCidr		= '192.168.10.{0}/24'
	IpTemplate = '192.168.10.{0}/24'
	UsedIPs    = @(200)                    # Liste des derniers octets utilisés
	VmIpMapping = @{}                      # Association VM → IP
  }

  Defaults = @{
    MemoryGB = 2
    VmSwitch = 'vSwitch-EXT1'
    VmPrefix = 'TST_'
  }

  Options = @{
    VerboseMode = $True                    # Affichage détaillé des logs (true: verbose, false: résultats finaux uniquement)
  }

  Scripts = @{
    Create   = 'CreateVmRemote.ps1'
    Remove   = 'RemoveVmRemote.ps1'
    Iso      = 'Create_Iso_Cidata.ps1'
    # CredFile = 'creds.xml'  # OBSOLÈTE : Remplacé par Windows Credential Manager
    # BaseDir = 'D:\MesScripts\UbuntuDeploy\ServeurDistantPowershell' # optionnel
  }
}
