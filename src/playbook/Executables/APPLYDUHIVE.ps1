# Load DefaultUser hive
$ErrorActionPreference = 'Stop'

$module = Get-Module -Name "FXPSYaml"
if (!$module) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module -Name FXPSYaml -Force | Out-Null
    Import-Module -Name FXPSYaml
}

$configurationFolder = Join-Path $PSScriptRoot "..\Configuration\tweaks"
$yamlFiles = Get-ChildItem -Path $configurationFolder -Filter *.yml -Recurse
$registryPaths = [System.Collections.Generic.HashSet[string]]::new()

foreach ($yamlFile in $yamlFiles) {
    $yamlContent = Get-Content $yamlFile.FullName -Raw
    $parsedYaml = ConvertFrom-Yaml $yamlContent

    foreach ($entry in $parsedYaml) {
        if (!$entry.actions) { continue }

        foreach ($action in $entry.actions) {
            if (!$action.path) { continue }

            $paths = if ($action.path -is [array]) { $action.path } else { @($action.path) }
            foreach ($path in $paths) {
                if ($path -like 'HKCU*') {
                    [void]$registryPaths.Add($path.Substring(4))
                }
            }
        }
    }
}

foreach ($path in $registryPaths) {
    $source = "Registry::HKCU\$path"
    $destination = "Registry::HKU\AME_UserHive_Default\$path"

    $values = Get-ItemProperty -Path $source -EA 0
    if (!$values) { continue }

    $propertyNames = $values.PSObject.Properties.Name | Where-Object { $_ -notin @("PSPath", "PSParentPath", "PSChildName", "PSDrive", "PSProvider") }

    if (!(Test-Path $destination)) {
        New-Item -Path $destination -Force | Out-Null
    }

    $existingProperties = (Get-ItemProperty $destination -EA 0).PSObject.Properties.Name

    foreach ($propertyName in $propertyNames) {
        $value = $values.$propertyName

        if ($existingProperties -contains $propertyName) {
            Set-ItemProperty -Path $destination -Name $propertyName -Value $value -EA 0
        } else {
            New-ItemProperty -Path $destination -Name $propertyName -Value $value -EA 0 | Out-Null
        }
    }
}
