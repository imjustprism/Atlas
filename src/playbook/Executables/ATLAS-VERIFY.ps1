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

function Test-RegistryAction {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }
    if ($null -eq $Action.value) { return }

    $paths = if ($Action.path -is [array]) { $Action.path } else { @($Action.path) }

    foreach ($path in $paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }

        $regPath = $path -replace '^HKLM\\', 'HKLM:\' -replace '^HKCU\\', 'HKCU:\' -replace '^HKU\\', 'Registry::HKU\' -replace '^HKCR\\', 'HKCR:\'
        $valueName = if ($Action.value -eq '') { '(Default)' } else { $Action.value }

        $isOptional = $path -match 'AME_UserHive_Default|HKCR|StorageSense|GameDVR|QuickAction|RunOnce|ShellNew|PropertyBag|MulticastDNS|powerscheme|\.pow|TrustedInstaller'
        $isConfigDependent = $valueName -match 'browser|TargetReleaseVersion|ExecutionPolicy|SettingsPageVisibility|UserPreferencesMask|ThisPCPolicy|ThemeFile|verbosestatus|AutoEndTasks'

        if (!(Test-Path $regPath -EA 0)) {
            $status = if ($isOptional) { 'WARN' } else { 'FAIL' }
            $details = if ($isOptional) { 'Optional path (expected to not exist)' } else { 'Path does not exist' }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" -Expected "Path exists" -Actual "Path missing" -Details $details
            return
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
            $status = if ($isOptional) { 'WARN' } else { 'FAIL' }
            $details = if ($isOptional) { 'Optional value (expected to not exist)' } else { "Value not found: $($_.Exception.Message)" }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" -Expected "Value: $($Action.data)" -Actual "NOT SET" -Details $details
            return
        }

        $valuesMatch = Compare-RegistryValue -Expected $Action.data -Actual $currentValue

        if (!$valuesMatch) {
            $status = if ($isConfigDependent) { 'WARN' } else { 'FAIL' }
            $details = if ($isConfigDependent) { 'Config-dependent value (may vary based on user choice)' } else { 'Value mismatch' }
            $expectedStr = if ($Action.data) { $Action.data } else { '(empty)' }
            $actualStr = if ($currentValue) { $currentValue } else { '(empty)' }
            Add-Result -Category 'Registry' -Status $status -Source $FileName -Item "$regPath\$valueName" -Expected $expectedStr -Actual $actualStr -Details $details
        } else {
            Add-Result -Category 'Registry' -Status 'PASS' -Source $FileName -Item "$regPath\$valueName" -Expected $Action.data -Actual $currentValue -Details 'Exact match'
        }
    }
}

function Test-ServiceAction {
    param($Action, $FileName)

    if ($null -eq $Action.name) { return }

    $serviceName = $Action.name
    $service = Get-Service -Name $serviceName -EA 0

    if (!$service) {
        Add-Result -Category 'Service' -Status 'FAIL' -Source $FileName -Item $serviceName -Expected "Service exists" -Actual "Service not found" -Details "Service does not exist"
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
            Add-Result -Category 'Service' -Status 'FAIL' -Source $FileName -Item $serviceName -Expected "StartType: $expectedStartup" -Actual "StartType: $actualStartup" -Details "Service startup type mismatch"
        } else {
            Add-Result -Category 'Service' -Status 'PASS' -Source $FileName -Item $serviceName -Expected $expectedStartup -Actual $actualStartup -Details 'Startup type matches'
        }
    }

    if ($Action.operation -eq 'stop') {
        if ($service.Status -ne 'Stopped') {
            Add-Result -Category 'Service' -Status 'FAIL' -Source $FileName -Item $serviceName -Expected "Status: Stopped" -Actual "Status: $($service.Status)" -Details "Service should be stopped"
        } else {
            Add-Result -Category 'Service' -Status 'PASS' -Source $FileName -Item $serviceName -Expected 'Stopped' -Actual $service.Status -Details 'Service is stopped'
        }
    }
}

function Test-ScheduledTaskAction {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }

    $taskPath = $Action.path
    $task = Get-ScheduledTask -TaskPath $taskPath -EA 0

    if ($Action.operation -eq 'delete') {
        if ($task) {
            Add-Result -Category 'ScheduledTask' -Status 'FAIL' -Source $FileName -Item $taskPath -Expected "Task deleted" -Actual "Task still exists" -Details "Scheduled task should be deleted"
        } else {
            Add-Result -Category 'ScheduledTask' -Status 'PASS' -Source $FileName -Item $taskPath -Expected 'Deleted' -Actual 'Not found' -Details 'Task deleted successfully'
        }
    } elseif ($Action.state -eq 'disabled') {
        if (!$task) {
            Add-Result -Category 'ScheduledTask' -Status 'SKIP' -Source $FileName -Item $taskPath -Expected "Task disabled" -Actual "Task not found" -Details "Task does not exist"
        } elseif ($task.State -ne 'Disabled') {
            Add-Result -Category 'ScheduledTask' -Status 'FAIL' -Source $FileName -Item $taskPath -Expected "State: Disabled" -Actual "State: $($task.State)" -Details "Task should be disabled"
        } else {
            Add-Result -Category 'ScheduledTask' -Status 'PASS' -Source $FileName -Item $taskPath -Expected 'Disabled' -Actual $task.State -Details 'Task is disabled'
        }
    }
}

function Test-FileAction {
    param($Action, $FileName)

    if ($null -eq $Action.path) { return }

    $filePath = $Action.path

    if ($Action.operation -eq 'delete') {
        if (Test-Path $filePath -EA 0) {
            Add-Result -Category 'File' -Status 'FAIL' -Source $FileName -Item $filePath -Expected "File deleted" -Actual "File exists" -Details "File should be deleted"
        } else {
            Add-Result -Category 'File' -Status 'PASS' -Source $FileName -Item $filePath -Expected 'Deleted' -Actual 'Not found' -Details 'File deleted successfully'
        }
    } elseif ($Action.operation -eq 'copy' -or $null -ne $Action.content) {
        if (!(Test-Path $filePath -EA 0)) {
            Add-Result -Category 'File' -Status 'FAIL' -Source $FileName -Item $filePath -Expected "File exists" -Actual "File not found" -Details "File should exist"
        } else {
            Add-Result -Category 'File' -Status 'PASS' -Source $FileName -Item $filePath -Expected 'Exists' -Actual 'Found' -Details 'File exists'
        }
    }
}

function Test-AppxAction {
    param($Action, $FileName)

    if ($null -eq $Action.name) { return }

    $appxName = $Action.name
    $appxPackages = Get-AppxPackage -Name $appxName -EA 0

    if ($appxPackages) {
        Add-Result -Category 'Appx' -Status 'WARN' -Source $FileName -Item $appxName -Expected "Package removed" -Actual "Package found: $($appxPackages.Count)" -Details "AppX package still installed (may reinstall on update)"
    } else {
        Add-Result -Category 'Appx' -Status 'PASS' -Source $FileName -Item $appxName -Expected 'Removed' -Actual 'Not found' -Details 'AppX package removed'
    }
}

try {
    Write-Header "Atlas Installation Verification Tool"
    Write-Output "Started: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    Write-Output "System: $([System.Environment]::OSVersion.VersionString)"
    Write-Output "Build: $([System.Environment]::OSVersion.Version.Build)"

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
                if ($null -eq $entry -or $null -eq $entry.actions) { continue }

                foreach ($action in $entry.actions) {
                    if ($null -eq $action) { continue }

                    $actionType = $action.PSObject.TypeNames | Where-Object { $_ -match 'registryValue|service|scheduledTask|file|appx' } | Select-Object -First 1

                    if ($null -ne $action.path -and $null -ne $action.value) {
                        Test-RegistryAction -Action $action -FileName $yamlFile.Name
                    } elseif ($null -ne $action.name -and ($actionType -match 'service' -or $null -ne $action.startup)) {
                        Test-ServiceAction -Action $action -FileName $yamlFile.Name
                    } elseif ($null -ne $action.path -and ($actionType -match 'scheduledTask' -or $null -ne $action.state)) {
                        Test-ScheduledTaskAction -Action $action -FileName $yamlFile.Name
                    } elseif ($null -ne $action.path -and $actionType -match 'file') {
                        Test-FileAction -Action $action -FileName $yamlFile.Name
                    } elseif ($null -ne $action.name -and $actionType -match 'appx') {
                        Test-AppxAction -Action $action -FileName $yamlFile.Name
                    }
                }
            }
        } catch {
            Add-Result -Category 'Registry' -Status 'SKIP' -Source $yamlFile.Name -Item 'File parsing' -Expected 'Valid YAML' -Actual 'Parse error' -Details $_.Exception.Message
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
    $output.Add("Build: $([System.Environment]::OSVersion.Version.Build)")
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
        $allChecks += $global:results."${category}Checks"
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
