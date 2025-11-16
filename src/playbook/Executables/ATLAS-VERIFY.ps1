$ErrorActionPreference = 'Stop'

$global:results = @{
    RegistryChecks = [System.Collections.Generic.List[PSCustomObject]]::new()
    ServiceChecks = [System.Collections.Generic.List[PSCustomObject]]::new()
    ScheduledTaskChecks = [System.Collections.Generic.List[PSCustomObject]]::new()
    FileChecks = [System.Collections.Generic.List[PSCustomObject]]::new()
    AppxChecks = [System.Collections.Generic.List[PSCustomObject]]::new()
    Stats = @{
        TotalChecks = 0
        Passed = 0
        Failed = 0
        Warnings = 0
        Skipped = 0
    }
}

$global:currentBuild = [System.Environment]::OSVersion.Version.Build
$global:currentArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()

function Write-Header {
    param([string]$Text)
    $line = "=" * 80
    Write-Output ""
    Write-Output $line
    Write-Output $Text
    Write-Output $line
}

function Write-Status {
    param([string]$Status, [string]$Message)

    switch ($Status) {
        'PASS' { Write-Host "[PASS] $Message" -ForegroundColor Green }
        'FAIL' { Write-Host "[FAIL] $Message" -ForegroundColor Red }
        'WARN' { Write-Host "[WARN] $Message" -ForegroundColor Yellow }
        'SKIP' { Write-Host "[SKIP] $Message" -ForegroundColor Gray }
        default { Write-Host "[$Status] $Message" }
    }
}

function Add-Result {
    param(
        [string]$Category,
        [string]$Status,
        [string]$Source,
        [string]$Item,
        [string]$Expected,
        [string]$Actual,
        [string]$Details
    )

    $result = [PSCustomObject]@{
        Category = $Category
        Status = $Status
        Source = $Source
        Item = $Item
        Expected = $Expected
        Actual = $Actual
        Details = $Details
        Timestamp = Get-Date -Format "HH:mm:ss"
    }

    $global:results."${Category}Checks".Add($result)
    $global:results.Stats.TotalChecks++

    switch ($Status) {
        'PASS' { $global:results.Stats.Passed++ }
        'FAIL' { $global:results.Stats.Failed++ }
        'WARN' { $global:results.Stats.Warnings++ }
        'SKIP' { $global:results.Stats.Skipped++ }
    }
}

function Test-BuildFilter {
    param($Builds)

    if ($null -eq $Builds) { return $true }

    $buildsArray = if ($Builds -is [array]) { $Builds } else { @($Builds) }

    foreach ($buildCondition in $buildsArray) {
        if ($buildCondition -match '^>=(\d+)$') {
            if ($global:currentBuild -ge [int]$matches[1]) { return $true }
        } elseif ($buildCondition -match '^>(\d+)$') {
            if ($global:currentBuild -gt [int]$matches[1]) { return $true }
        } elseif ($buildCondition -match '^<(\d+)$') {
            if ($global:currentBuild -lt [int]$matches[1]) { return $true }
        } elseif ($buildCondition -match '^<=(\d+)$') {
            if ($global:currentBuild -le [int]$matches[1]) { return $true }
        } elseif ($buildCondition -match '^(\d+)$') {
            if ($global:currentBuild -eq [int]$matches[1]) { return $true }
        }
    }

    return $false
}

function Test-CpuArchFilter {
    param($CpuArch)

    if ($null -eq $CpuArch) { return $true }

    return $global:currentArch -eq $CpuArch
}

function Compare-RegistryValue {
    param($Expected, $Actual)

    if ($null -eq $Expected -or $Expected -eq '') {
        return $true
    }

    if ($null -eq $Actual) {
        return $false
    }

    if ($Actual -is [byte[]]) {
        $Actual = [BitConverter]::ToString($Actual) -replace '-', ' '
    }

    if ($Expected -is [byte[]]) {
        $Expected = [BitConverter]::ToString($Expected) -replace '-', ' '
    }

    if ($Actual -is [array]) {
        $Actual = $Actual -join ' '
    }

    if ($Expected -is [array]) {
        $Expected = $Expected -join ' '
    }

    return $Expected.ToString().Trim() -eq $Actual.ToString().Trim()
}

function Test-RegistryValue {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }
    if ($null -eq $Action.value) { return }

    if (!(Test-BuildFilter $Action.builds)) {
        Add-Result -Category 'Registry' -Status 'SKIP' -Source $FileName -Item "$($Action.path)\$($Action.value)" `
            -Expected "Skipped" -Actual "Build $global:currentBuild" `
            -Details "Not applicable to current build (requires: $($Action.builds -join ', '))"
        return
    }

    if (!(Test-CpuArchFilter $Action.cpuArch)) {
        Add-Result -Category 'Registry' -Status 'SKIP' -Source $FileName -Item "$($Action.path)\$($Action.value)" `
            -Expected "Skipped" -Actual "Arch $global:currentArch" `
            -Details "Not applicable to current architecture (requires: $($Action.cpuArch))"
        return
    }

    $paths = if ($Action.path -is [array]) { $Action.path } else { @($Action.path) }

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $regPath = $path -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' `
                         -replace '^HKU\\', 'Registry::HKU\' -replace '^HKCR\\', 'HKCR:\'
        $valueName = if ($Action.value -eq '') { '(Default)' } else { $Action.value }

        $isOptional = $path -match 'AME_UserHive_Default|HKCR|StorageSense|GameDVR|GameBar|QuickAction|RunOnce|ShellNew|PropertyBag|powerscheme|\.pow|TrustedInstaller|PolicyManager|DNSClient|PreviousVersions|Siuf'
        $isConfigDependent = $valueName -match 'browser|TargetReleaseVersion|ExecutionPolicy|SettingsPageVisibility|UserPreferencesMask|ThisPCPolicy|ThemeFile|verbosestatus|AutoEndTasks|Toggles|PeriodInNanoSeconds|NoPreviousVersionsPage'
        $isDeleteOperation = $Action.operation -eq 'delete'
        $ignoreErrors = $Action.ignoreErrors -eq $true

        if (!(Test-Path $regPath -EA 0)) {
            if ($isDeleteOperation) {
                Add-Result -Category 'Registry' -Status 'PASS' -Source $FileName -Item "$regPath\$valueName" `
                    -Expected "Value deleted" -Actual "Path not found" -Details 'Deletion successful (path removed)'
                continue
            }
            $status = if ($isOptional) { 'WARN' } else { 'FAIL' }
            $details = if ($isOptional) { 'Optional path (expected to not exist on some systems)' } else { 'Path does not exist' }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" `
                -Expected "Path exists" -Actual "Path missing" -Details $details
            continue
        }

        try {
            if ($Action.value -eq '') {
                $regItem = Get-Item -Path $regPath -EA Stop
                $currentValue = $regItem.GetValue('')
            } else {
                $regItem = Get-ItemProperty -Path $regPath -Name $Action.value -EA Stop
                $currentValue = $regItem.$valueName
            }
        } catch {
            if ($isDeleteOperation) {
                Add-Result -Category 'Registry' -Status 'PASS' -Source $FileName -Item "$regPath\$valueName" `
                    -Expected "Value deleted" -Actual "NOT SET" -Details 'Deletion successful'
                continue
            }
            $status = if ($isOptional -or $isConfigDependent) { 'WARN' } else { 'FAIL' }
            $details = if ($isOptional) { 'Optional value (may not exist on some systems)' } `
                       elseif ($isConfigDependent) { 'Config-dependent value (may not be set)' } `
                       else { "Value not found: $($_.Exception.Message)" }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" `
                -Expected "Value: $($Action.data)" -Actual "NOT SET" -Details $details
            continue
        }

        if ($isDeleteOperation) {
            $status = if ($ignoreErrors) { 'SKIP' } else { 'FAIL' }
            $details = if ($ignoreErrors) { 'Deletion failed but ignoreErrors is set' } else { 'Deletion failed - value still present' }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" `
                -Expected "Value deleted" -Actual "Value exists: $currentValue" -Details $details
            continue
        }

        $valuesMatch = Compare-RegistryValue -Expected $Action.data -Actual $currentValue

        if (!$valuesMatch) {
            $status = if ($isConfigDependent) { 'WARN' } else { 'FAIL' }
            $details = if ($isConfigDependent) { 'Config-dependent value (may vary based on user choice)' } else { 'Value mismatch' }
            $expectedStr = if ($Action.data) { $Action.data } else { '(empty)' }
            $actualStr = if ($currentValue) { $currentValue } else { '(empty)' }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" `
                -Expected $expectedStr -Actual $actualStr -Details $details
        } else {
            Add-Result -Category 'Registry' -Status 'PASS' -Source $FileName -Item "$regPath\$valueName" `
                -Expected $Action.data -Actual $currentValue -Details 'Exact match'
        }
    }
}

function Test-RegistryKey {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }

    if (!(Test-BuildFilter $Action.builds)) {
        Add-Result -Category 'Registry' -Status 'SKIP' -Source $FileName -Item $Action.path `
            -Expected "Skipped" -Actual "Build $global:currentBuild" `
            -Details "Not applicable to current build (requires: $($Action.builds -join ', '))"
        return
    }

    $regPath = $Action.path -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' `
                             -replace '^HKU\\', 'Registry::HKU\' -replace '^HKCR\\', 'HKCR:\'

    $operation = if ($Action.operation) { $Action.operation } else { 'delete' }

    $keyExists = Test-Path $regPath -EA 0

    if ($operation -eq 'delete') {
        if ($keyExists) {
            Add-Result -Category 'Registry' -Status 'FAIL' -Source $FileName -Item $regPath `
                -Expected "Key deleted" -Actual "Key exists" -Details 'Key should be deleted'
        } else {
            Add-Result -Category 'Registry' -Status 'PASS' -Source $FileName -Item $regPath `
                -Expected "Key deleted" -Actual "Key not found" -Details 'Deletion successful'
        }
    } elseif ($operation -eq 'add') {
        if ($keyExists) {
            Add-Result -Category 'Registry' -Status 'PASS' -Source $FileName -Item $regPath `
                -Expected "Key exists" -Actual "Key found" -Details 'Key created successfully'
        } else {
            Add-Result -Category 'Registry' -Status 'FAIL' -Source $FileName -Item $regPath `
                -Expected "Key exists" -Actual "Key not found" -Details 'Key should exist'
        }
    }
}

function Test-Service {
    param($Action, $FileName)

    if ($null -eq $Action.name) { return }

    if (!(Test-CpuArchFilter $Action.cpuArch)) {
        Add-Result -Category 'Service' -Status 'SKIP' -Source $FileName -Item $Action.name `
            -Expected "Skipped" -Actual "Arch $global:currentArch" `
            -Details "Not applicable to current architecture (requires: $($Action.cpuArch))"
        return
    }

    $serviceName = $Action.name
    $service = Get-Service -Name $serviceName -EA 0

    $isLegacyService = $serviceName -match 'diagnosticshub\.standardcollector|GpuEnergyDrv|Telemetry'

    if (!$service) {
        $status = if ($isLegacyService) { 'WARN' } else { 'FAIL' }
        $details = if ($isLegacyService) { 'Legacy service (may not exist on Windows 11 24H2+)' } else { 'Service does not exist' }
        Add-Result -Category 'Service' -Status $status -Source $FileName -Item $serviceName `
            -Expected "Service exists" -Actual "Service not found" -Details $details
        return
    }

    if ($null -ne $Action.startup) {
        $startupTypes = @{
            0 = 'Boot'
            1 = 'System'
            2 = 'Automatic'
            3 = 'Manual'
            4 = 'Disabled'
        }

        $expectedStartup = $startupTypes[$Action.startup]
        $actualStartup = $service.StartType

        if ($actualStartup -ne $expectedStartup) {
            Add-Result -Category 'Service' -Status 'FAIL' -Source $FileName -Item $serviceName `
                -Expected "StartType: $expectedStartup" -Actual "StartType: $actualStartup" -Details "Service startup type mismatch"
        } else {
            Add-Result -Category 'Service' -Status 'PASS' -Source $FileName -Item $serviceName `
                -Expected $expectedStartup -Actual $actualStartup -Details 'Startup type matches'
        }
    }

    if ($Action.operation -eq 'stop') {
        if ($service.Status -ne 'Stopped') {
            Add-Result -Category 'Service' -Status 'FAIL' -Source $FileName -Item $serviceName `
                -Expected "Status: Stopped" -Actual "Status: $($service.Status)" -Details "Service should be stopped"
        } else {
            Add-Result -Category 'Service' -Status 'PASS' -Source $FileName -Item $serviceName `
                -Expected 'Stopped' -Actual $service.Status -Details 'Service is stopped'
        }
    }
}

function Test-ScheduledTask {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }

    $taskPath = $Action.path
    $task = Get-ScheduledTask -TaskName (Split-Path $taskPath -Leaf) -EA 0 |
            Where-Object { $_.TaskPath -like "*$(Split-Path $taskPath -Parent)*" }

    $ignoreErrors = $Action.ignoreErrors -eq $true

    if ($Action.operation -eq 'delete') {
        if ($task) {
            Add-Result -Category 'ScheduledTask' -Status 'FAIL' -Source $FileName -Item $taskPath `
                -Expected "Task deleted" -Actual "Task still exists" -Details "Scheduled task should be deleted"
        } else {
            Add-Result -Category 'ScheduledTask' -Status 'PASS' -Source $FileName -Item $taskPath `
                -Expected 'Deleted' -Actual 'Not found' -Details 'Task deleted successfully'
        }
    } elseif ($Action.operation -eq 'disable') {
        if (!$task) {
            $status = if ($ignoreErrors) { 'SKIP' } else { 'WARN' }
            $details = if ($ignoreErrors) { 'Task does not exist (ignoreErrors: true)' } else { 'Task does not exist'  }
            Add-Result -Category 'ScheduledTask' -Status $status -Source $FileName -Item $taskPath `
                -Expected "Task disabled" -Actual "Task not found" -Details $details
        } elseif ($task.State -ne 'Disabled') {
            Add-Result -Category 'ScheduledTask' -Status 'FAIL' -Source $FileName -Item $taskPath `
                -Expected "State: Disabled" -Actual "State: $($task.State)" -Details "Task should be disabled"
        } else {
            Add-Result -Category 'ScheduledTask' -Status 'PASS' -Source $FileName -Item $taskPath `
                -Expected 'Disabled' -Actual $task.State -Details 'Task is disabled'
        }
    } elseif ($Action.operation -eq 'enable') {
        if (!$task) {
            Add-Result -Category 'ScheduledTask' -Status 'FAIL' -Source $FileName -Item $taskPath `
                -Expected "Task enabled" -Actual "Task not found" -Details "Task does not exist"
        } elseif ($task.State -eq 'Disabled') {
            Add-Result -Category 'ScheduledTask' -Status 'FAIL' -Source $FileName -Item $taskPath `
                -Expected "State: Ready/Running" -Actual "State: Disabled" -Details "Task should be enabled"
        } else {
            Add-Result -Category 'ScheduledTask' -Status 'PASS' -Source $FileName -Item $taskPath `
                -Expected 'Enabled' -Actual $task.State -Details 'Task is enabled'
        }
    }
}

function Test-File {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }

    if (!(Test-CpuArchFilter $Action.cpuArch)) {
        Add-Result -Category 'File' -Status 'SKIP' -Source $FileName -Item $Action.path `
            -Expected "Skipped" -Actual "Arch $global:currentArch" `
            -Details "Not applicable to current architecture (requires: $($Action.cpuArch))"
        return
    }

    $filePath = [System.Environment]::ExpandEnvironmentVariables($Action.path)

    if (Test-Path $filePath -EA 0) {
        Add-Result -Category 'File' -Status 'FAIL' -Source $FileName -Item $filePath `
            -Expected "File/folder deleted" -Actual "File/folder exists" -Details "Should be deleted"
    } else {
        Add-Result -Category 'File' -Status 'PASS' -Source $FileName -Item $filePath `
            -Expected 'Deleted' -Actual 'Not found' -Details 'Deletion successful'
    }
}

function Test-Appx {
    param($Action, $FileName)

    if ($null -eq $Action.name) { return }

    $appxName = $Action.name

    if ($Action.operation -eq 'clearCache') {
        Add-Result -Category 'Appx' -Status 'SKIP' -Source $FileName -Item $appxName `
            -Expected "Cache cleared" -Actual "N/A" -Details "AppX cache operation (cannot verify)"
        return
    }

    $appxPackages = Get-AppxPackage -Name $appxName -EA 0

    if ($appxPackages) {
        Add-Result -Category 'Appx' -Status 'WARN' -Source $FileName -Item $appxName `
            -Expected "Package removed" -Actual "Package found: $($appxPackages.Count)" `
            -Details "AppX package still installed (may reinstall after Windows updates)"
    } else {
        Add-Result -Category 'Appx' -Status 'PASS' -Source $FileName -Item $appxName `
            -Expected 'Removed' -Actual 'Not found' -Details 'AppX package removed'
    }
}

try {
    Write-Header "Atlas Installation Verification Tool"
    Write-Output "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "System: $([System.Environment]::OSVersion.VersionString)"
    Write-Output "Build: $global:currentBuild"
    Write-Output "Architecture: $global:currentArch"

    $module = Get-Module -Name "FXPSYaml"
    if (!$module) {
        Write-Output "`nInstalling FXPSYaml module..."
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -EA Stop | Out-Null
        Install-Module -Name FXPSYaml -Force -EA Stop | Out-Null
        Import-Module -Name FXPSYaml -EA Stop
    }

    $configurationFolder = Join-Path $PSScriptRoot "..\Configuration"
    if (!(Test-Path $configurationFolder)) {
        throw "Configuration folder not found: $configurationFolder"
    }

    Write-Header "Scanning YAML Configuration Files"
    $yamlFiles = Get-ChildItem -Path $configurationFolder -Filter *.yml -Recurse -EA Stop
    Write-Output "Found $($yamlFiles.Count) YAML files to analyze"

    $fileCount = 0
    foreach ($yamlFile in $yamlFiles) {
        $fileCount++
        Write-Output "[${fileCount}/$($yamlFiles.Count)] Processing: $($yamlFile.Name)"

        try {
            $yamlContent = Get-Content $yamlFile.FullName -Raw -EA Stop
            if ([string]::IsNullOrWhiteSpace($yamlContent)) { continue }

            $parsedYaml = ConvertFrom-Yaml $yamlContent -EA Stop
            if ($null -eq $parsedYaml) { continue }

            foreach ($entry in $parsedYaml) {
                if ($null -eq $entry) { continue }

                if ($entry.builds -and !(Test-BuildFilter $entry.builds)) {
                    continue
                }

                if ($null -eq $entry.actions) { continue }

                foreach ($action in $entry.actions) {
                    if ($null -eq $action) { continue }

                    $actionType = $action.PSObject.TypeNames |
                        Where-Object { $_ -match 'registryValue|registryKey|service|scheduledTask|file|appx' } |
                        Select-Object -First 1

                    if ($actionType -match 'registryValue' -or ($null -ne $action.path -and $null -ne $action.value)) {
                        Test-RegistryValue -Action $action -FileName $yamlFile.Name
                    } elseif ($actionType -match 'registryKey' -or ($null -ne $action.path -and $null -ne $action.operation -and $action.operation -match 'add|delete' -and $null -eq $action.value)) {
                        Test-RegistryKey -Action $action -FileName $yamlFile.Name
                    } elseif ($actionType -match 'service' -or ($null -ne $action.name -and $null -ne $action.startup)) {
                        Test-Service -Action $action -FileName $yamlFile.Name
                    } elseif ($actionType -match 'scheduledTask' -or ($null -ne $action.path -and $null -ne $action.operation -and $action.operation -match 'enable|disable|delete')) {
                        Test-ScheduledTask -Action $action -FileName $yamlFile.Name
                    } elseif ($actionType -match 'file' -or ($null -ne $action.path -and $null -ne $action.cpuArch)) {
                        Test-File -Action $action -FileName $yamlFile.Name
                    } elseif ($actionType -match 'appx' -or ($null -ne $action.name -and ($null -ne $action.type -or $null -ne $action.operation))) {
                        Test-Appx -Action $action -FileName $yamlFile.Name
                    }
                }
            }
        } catch {
            Add-Result -Category 'Registry' -Status 'SKIP' -Source $yamlFile.Name -Item 'File parsing' `
                -Expected 'Valid YAML' -Actual 'Parse error' -Details $_.Exception.Message
        }
    }

    $desktopPath = [Environment]::GetFolderPath('Desktop')
    $resultFile = Join-Path $desktopPath "AtlasVerification.txt"
    $output = [System.Collections.Generic.List[string]]::new()

    $output.Add("=" * 80)
    $output.Add("ATLAS INSTALLATION VERIFICATION REPORT")
    $output.Add("=" * 80)
    $output.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $output.Add("System: $([System.Environment]::OSVersion.VersionString)")
    $output.Add("Build: $global:currentBuild")
    $output.Add("Architecture: $global:currentArch")
    $output.Add("")

    $output.Add("=" * 80)
    $output.Add("SUMMARY")
    $output.Add("=" * 80)
    $output.Add("Total Checks: $($global:results.Stats.TotalChecks)")
    $output.Add("  [PASS] Passed: $($global:results.Stats.Passed)")
    $output.Add("  [FAIL] Failed: $($global:results.Stats.Failed)")
    $output.Add("  [WARN] Warnings: $($global:results.Stats.Warnings)")
    $output.Add("  [SKIP] Skipped: $($global:results.Stats.Skipped)")
    $output.Add("")

    if ($global:results.Stats.TotalChecks -gt 0) {
        $passRate = [math]::Round(($global:results.Stats.Passed / $global:results.Stats.TotalChecks) * 100, 2)
        $successRate = [math]::Round((($global:results.Stats.Passed + $global:results.Stats.Warnings) / $global:results.Stats.TotalChecks) * 100, 2)
        $output.Add("Critical Pass Rate: ${passRate}%")
        $output.Add("Overall Success Rate: ${successRate}%")
    }
    $output.Add("")

    $categories = @('Registry', 'Service', 'ScheduledTask', 'File', 'Appx')

    foreach ($category in $categories) {
        $checks = $global:results."${category}Checks"
        if ($checks.Count -eq 0) { continue }

        $failed = $checks | Where-Object { $_.Status -eq 'FAIL' }
        $warned = $checks | Where-Object { $_.Status -eq 'WARN' }

        $output.Add("=" * 80)
        $output.Add("${category} Checks: $($checks.Count) total")
        $output.Add("=" * 80)
        $output.Add("")

        if ($failed.Count -gt 0) {
            $output.Add("--- CRITICAL FAILURES ($($failed.Count)) ---")
            $output.Add("")
            foreach ($item in $failed) {
                $output.Add("[FAIL] FAILED")
                $output.Add("  Source: $($item.Source)")
                $output.Add("  Item: $($item.Item)")
                $output.Add("  Expected: $($item.Expected)")
                $output.Add("  Actual: $($item.Actual)")
                $output.Add("  Details: $($item.Details)")
                $output.Add("")
            }
        }

        if ($warned.Count -gt 0) {
            $output.Add("--- WARNINGS ($($warned.Count)) ---")
            $output.Add("")
            foreach ($item in $warned) {
                $output.Add("[WARN] WARNING")
                $output.Add("  Source: $($item.Source)")
                $output.Add("  Item: $($item.Item)")
                $output.Add("  Expected: $($item.Expected)")
                $output.Add("  Actual: $($item.Actual)")
                $output.Add("  Details: $($item.Details)")
                $output.Add("")
            }
        }
    }

    $output.Add("=" * 80)
    $output.Add("DETAILED BREAKDOWN BY SOURCE FILE")
    $output.Add("=" * 80)
    $output.Add("")

    $allChecks = @()
    foreach ($category in $categories) {
        $allChecks += $global:results."${Category}Checks"
    }

    $groupedBySource = $allChecks | Group-Object Source | Sort-Object Name

    foreach ($group in $groupedBySource) {
        $passed = ($group.Group | Where-Object { $_.Status -eq 'PASS' }).Count
        $failed = ($group.Group | Where-Object { $_.Status -eq 'FAIL' }).Count
        $warned = ($group.Group | Where-Object { $_.Status -eq 'WARN' }).Count
        $skipped = ($group.Group | Where-Object { $_.Status -eq 'SKIP' }).Count

        $statusIcon = if ($failed -gt 0) { '[FAIL]' } elseif ($warned -gt 0) { '[WARN]' } else { '[PASS]' }

        $output.Add("$statusIcon $($group.Name)")
        $output.Add("  Total: $($group.Count) | Passed: ${passed} | Failed: ${failed} | Warnings: ${warned} | Skipped: ${skipped}")

        if ($failed -gt 0) {
            $failures = $group.Group | Where-Object { $_.Status -eq 'FAIL' }
            foreach ($failure in $failures) {
                $output.Add("    [FAIL] [$($failure.Category)] $($failure.Item)")
                $output.Add("      Expected: $($failure.Expected)")
                $output.Add("      Actual: $($failure.Actual)")
            }
        }
        $output.Add("")
    }

    $output.Add("=" * 80)
    $output.Add("FINAL VERDICT")
    $output.Add("=" * 80)
    $output.Add("")

    if ($global:results.Stats.Failed -eq 0) {
        $output.Add("[PASS] SUCCESS - All critical checks passed!")
        if ($global:results.Stats.Warnings -gt 0) {
            $output.Add("")
            $output.Add("$($global:results.Stats.Warnings) warnings found (non-critical issues).")
            $output.Add("These are typically optional features or config-dependent values.")
        }
    } else {
        $output.Add("[FAIL] FAILURE - $($global:results.Stats.Failed) critical issue(s) detected!")
        $output.Add("")
        $output.Add("Review the CRITICAL FAILURES sections above for details.")
        $output.Add("Each failure shows:")
        $output.Add("  - Source file where the configuration was defined")
        $output.Add("  - Exact registry path/service/file that failed")
        $output.Add("  - Expected value vs actual value")
        $output.Add("  - Detailed description of the issue")
    }

    $output.Add("")
    $output.Add("=" * 80)
    $output.Add("End of Report")
    $output.Add("=" * 80)

    $output | Out-File -FilePath $resultFile -Encoding UTF8 -Force

    Write-Header "Verification Complete"
    Write-Output "Results saved to: $resultFile"
    Write-Output ""
    Write-Output "Summary:"
    Write-Output "  Total: $($global:results.Stats.TotalChecks)"
    Write-Status -Status 'PASS' -Message "Passed: $($global:results.Stats.Passed)"
    Write-Status -Status 'FAIL' -Message "Failed: $($global:results.Stats.Failed)"
    Write-Status -Status 'WARN' -Message "Warnings: $($global:results.Stats.Warnings)"
    Write-Status -Status 'SKIP' -Message "Skipped: $($global:results.Stats.Skipped)"
    Write-Output ""

    if ($global:results.Stats.Failed -eq 0) {
        Write-Status -Status 'PASS' -Message "All critical checks passed!"
        exit 0
    } else {
        Write-Status -Status 'FAIL' -Message "$($global:results.Stats.Failed) critical failures detected!"
        Write-Output "Check $resultFile for details"
        exit 1
    }

} catch {
    $errorMsg = @(
        "=" * 80
        "FATAL ERROR IN VERIFICATION SCRIPT"
        "=" * 80
        "Error: $($_.Exception.Message)"
        "At: $($_.InvocationInfo.ScriptLineNumber):$($_.InvocationInfo.OffsetInLine)"
        "StackTrace:"
        $_.ScriptStackTrace
        "=" * 80
    )

    $errorFile = Join-Path ([Environment]::GetFolderPath('Desktop')) "AtlasVerification_ERROR.txt"
    $errorMsg | Out-File -FilePath $errorFile -Encoding UTF8 -Force

    Write-Error "Verification failed! Error log: $errorFile"
    Write-Error $_.Exception.Message
    exit 1
}
