# Requires: PowerShell 7 (pwsh) recommended
$ErrorActionPreference = "SilentlyContinue"

Write-Host "== Windows Host Audit =="

# OS
$os = Get-ComputerInfo | Select-Object OsName, OsVersion, OsBuildNumber
Write-Host ("OS: {0} {1} (Build {2})" -f $os.OsName, $os.OsVersion, $os.OsBuildNumber)

# WSL version + distros
wsl.exe --version
wsl.exe -l -v

# Virtualization check
$vm = Get-CimInstance -ClassName Win32_Processor | Select-Object -ExpandProperty VirtualizationFirmwareEnabled
Write-Host ("VirtualizationFirmwareEnabled: {0}" -f $vm)

# Network adapters
Get-NetAdapter | Where-Object {$_.Status -eq "Up"} | Select-Object Name,InterfaceDescription,Status | Format-Table

# Listening ports (top common ones)
$ports = 80,443,8080,8200,8201,3000,15672,15692,5672,19999,4317,4318,8000,8443,4822,4444,4445,4433,4434,5678
Write-Host "`nListening ports (common set):"
foreach ($p in $ports) {
  $inuse = (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction SilentlyContinue)
  if ($inuse) { Write-Host (" - Port {0}: LISTEN" -f $p) }
}

Write-Host "== Windows audit done =="
