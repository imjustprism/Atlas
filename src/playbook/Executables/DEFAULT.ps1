if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
  Start-Process powershell.exe "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs; exit
}

$windir = [Environment]::GetFolderPath('Windows')
$defaultScripts = Get-ChildItem -Path "$windir\AtlasDesktop" -Filter "*default*.cmd" -File -Recurse

foreach ($script in $defaultScripts) {
  if ($script.Name -match '\(default\)\.cmd$') {
    Write-Host $script.Name
    Start-Process -FilePath $script.FullName -ArgumentList "/silent /noAction" -Wait -WindowStyle Hidden
  }
}
exit 0
