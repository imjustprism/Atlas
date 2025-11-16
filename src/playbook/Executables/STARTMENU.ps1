.\AtlasModules\initPowerShell.ps1

foreach ($userKey in (Get-RegUserPaths).PsPath) {
    $default = if ($userKey -match 'AME_UserHive_Default') { $true }
    $sid = Split-Path $userKey -Leaf

    # Get Local AppData
    $appData = if ($default) {
        Get-UserPath -Folder 'F1B32785-6FBA-4FCF-9D55-7B8E7F157091'
    } else {
        (Get-ItemProperty "$userKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders" -Name 'Local AppData' -EA 0).'Local AppData'
    }

    Write-Title "Configuring Start Menu for '$sid'..."
    if ([string]::IsNullOrEmpty($appData) -or !(Test-Path $appData)) {
        Write-Error "Couldn't find AppData value for $sid!"
    } else {
        Write-Output "Copying default layout XML"
        $layoutPath = "$appdata\Microsoft\Windows\Shell"
        if (!(Test-Path $layoutPath)) {
            New-Item -Path $layoutPath -ItemType Directory -Force | Out-Null
        }
        Copy-Item -Path "Layout.xml" -Destination "$layoutPath\LayoutModification.xml" -Force

        if (!$default) {
            Write-Output "Clearing Start Menu pinned items"
            $packages = Get-ChildItem -Path "$appdata\Packages" -Directory -Filter "*StartMenuExperienceHost*" -EA 0
            foreach ($package in $packages) {
                $bins = Get-ChildItem -Path "$appdata\Packages\$($package.Name)\LocalState" -Filter "start*.bin" -File -EA 0
                if ($bins) {
                    Remove-Item -Path $bins.FullName -Force -EA 0
                }
            }
        }
    }

    if (!$default) {
        Write-Output "Clearing default 'tilegrid'"
        $cloudStorePath = "$userKey\SOFTWARE\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount"
        if (Test-Path $cloudStorePath) {
            Get-ChildItem -Path $cloudStorePath -Recurse -EA 0 | Where-Object { $_.Name -match "start\.tilegrid" } | Remove-Item -Force -EA 0
        }
    }

    Write-Output "Removing advertisements/stubs from Start Menu (23H2+)"
    Remove-ItemProperty -Path "$userKey\SOFTWARE\Microsoft\Windows\CurrentVersion\Start" -Name 'Config' -Force -EA 0
}
