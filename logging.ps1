# logging.ps1

$Script:LogFile   = Join-Path $PSScriptRoot "deploy.log"
$Script:MaxLines  = 1000
$Script:LogBuffer = New-Object System.Collections.Generic.Queue[string]

# Charger l’existant (si présent)
if (Test-Path $Script:LogFile) {
    Get-Content $Script:LogFile | ForEach-Object {
        $Script:LogBuffer.Enqueue($_)
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"

    $Script:LogBuffer.Enqueue($entry)

    while ($Script:LogBuffer.Count -gt $Script:MaxLines) {
        $Script:LogBuffer.Dequeue() | Out-Null
    }
}

function Flush-Logs {
    Set-Content -Path $Script:LogFile -Value $Script:LogBuffer
}
