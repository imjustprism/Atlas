# Speeds up PowerShell startup time by 10x
$env:path = "$([Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory());" + $env:path
$assemblies = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object Location | Select-Object -ExpandProperty Location
foreach ($assembly in $assemblies) {
    Write-Host "NGENing: $(Split-Path $assembly -Leaf)" -ForegroundColor Yellow
    ngen install $assembly > $null 2>&1
}
