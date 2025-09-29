@{
  RemoteHost = '192.168.10.201'

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
	PoolStart  = 200                       # 1ère IP: .200
	PoolEnd    = 250                       # Dernière IP: .250
	IpCidr		= '192.168.10.{0}/24'
	IpTemplate = '192.168.10.{0}/24'
	UsedIPs    = @()                       # Liste des derniers octets utilisés
	VmIpMapping = @{}                      # Association VM → IP
  }

  Defaults = @{
    MemoryGB = 2
    VmSwitch = 'vSwitch-EXT1'
    VmPrefix = 'TST_'
  }

  Scripts = @{
    Create   = 'CreateVmRemote.ps1'
    Remove   = 'RemoveVmRemote.ps1'
    Iso      = 'Create_Iso_Cidata.ps1'
    CredFile = 'creds.xml'
    # BaseDir = 'D:\MesScripts\UbuntuDeploy\ServeurDistantPowershell' # optionnel
  }
}
