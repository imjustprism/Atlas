param(
    [switch]$UninstallEdge,
    [switch]$RemoveEdgeData,
    [switch]$KeepAppX,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$programFilesX86 = [Environment]::GetFolderPath('ProgramFilesX86')
$windir = [Environment]::GetFolderPath('Windows')
$localAppData = [Environment]::GetFolderPath('LocalApplicationData')

function Write-Status {
    param([string]$Message, [string]$Level = 'Info')

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error' { 'Red' }
        default { 'White' }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Stop-EdgeProcesses {
    Get-Process -EA 0 | Where-Object {
        $_.Path -like "$programFilesX86\Microsoft\Edge\*" -or
        $_.Name -like '*msedge*' -or
        $_.Name -like '*edge*'
    } | Stop-Process -Force -EA 0

    Get-Service -EA 0 | Where-Object {
        $_.DisplayName -like '*Microsoft Edge*'
    } | Stop-Service -Force -EA 0
}

function Remove-EdgeSetup {
    $edgePath = "$programFilesX86\Microsoft\Edge\Application"
    $setupPath = Get-ChildItem -Path $edgePath -Recurse -Filter "setup.exe" -EA 0 |
        Select-Object -First 1 -ExpandProperty FullName

    if (!$setupPath) {
        Write-Status "Edge setup.exe not found, skipping uninstaller" -Level Warning
        return
    }

    Write-Status "Running Edge uninstaller..."
    $uninstallArgs = "--uninstall --system-level --force-uninstall --verbose-logging"
    Start-Process -FilePath $setupPath -ArgumentList $uninstallArgs -Wait -NoNewWindow -EA 0
}

function Remove-EdgeAppX {
    if ($KeepAppX) {
        Write-Status "Skipping AppX removal (KeepAppX flag set)"
        return
    }

    Write-Status "Removing Edge AppX packages..."

    $edgePackages = Get-AppxPackage -AllUsers -EA 0 | Where-Object {
        $_.Name -like '*MicrosoftEdge*'
    }

    foreach ($pkg in $edgePackages) {
        Write-Status "Removing AppX: $($pkg.PackageFullName)"
        Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -EA 0
    }

    $deprovisionPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\Deprovisioned'
    $edgeAppxNames = @(
        'Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe',
        'Microsoft.MicrosoftEdge_8wekyb3d8bbwe'
    )

    foreach ($appxName in $edgeAppxNames) {
        $keyPath = "$deprovisionPath\$appxName"
        if (!(Test-Path $keyPath)) {
            New-Item -Path $keyPath -Force -EA 0 | Out-Null
        }
    }
}

function Remove-EdgeRegistry {
    Write-Status "Cleaning Edge registry entries..."

    $registryPaths = @(
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Edge',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate',
        'HKLM:\SOFTWARE\Microsoft\Edge',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate',
        'HKCU:\Software\Microsoft\Edge',
        'HKCU:\Software\Microsoft\EdgeUpdate'
    )

    foreach ($regPath in $registryPaths) {
        if (Test-Path $regPath) {
            Remove-Item -Path $regPath -Recurse -Force -EA 0
        }
    }

    $appxStorePath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore'
    if (Test-Path $appxStorePath) {
        Get-ChildItem -Path $appxStorePath -Recurse -EA 0 | Where-Object {
            $_.PSChildName -like '*MicrosoftEdge*'
        } | Remove-Item -Recurse -Force -EA 0
    }
}

function Remove-EdgeFiles {
    Write-Status "Removing Edge files and folders..."

    $edgeFolders = @(
        "$programFilesX86\Microsoft\Edge",
        "$programFilesX86\Microsoft\EdgeUpdate",
        "$programFilesX86\Microsoft\EdgeCore",
        "$windir\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe"
    )

    foreach ($folder in $edgeFolders) {
        if (Test-Path $folder) {
            Write-Status "Removing: $folder"

            takeown /F $folder /R /D Y > $null 2>&1
            icacls $folder /grant "BUILTIN\Administrators:(F)" /T /C /Q > $null 2>&1
            icacls $folder /grant "Everyone:(F)" /T /C /Q > $null 2>&1

            Remove-Item -Path $folder -Recurse -Force -EA 0
        }
    }

    $shortcuts = @(
        "$env:PUBLIC\Desktop\Microsoft Edge.lnk",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
    )

    foreach ($shortcut in $shortcuts) {
        if (Test-Path $shortcut) {
            Remove-Item -Path $shortcut -Force -EA 0
        }
    }
}

function Remove-EdgeScheduledTasks {
    Write-Status "Removing Edge scheduled tasks..."

    Get-ScheduledTask -EA 0 | Where-Object {
        $_.TaskName -like '*MicrosoftEdge*'
    } | Unregister-ScheduledTask -Confirm:$false -EA 0
}

function Remove-EdgeServices {
    Write-Status "Removing Edge services..."

    $edgeServices = @(
        'edgeupdate',
        'edgeupdatem',
        'MicrosoftEdgeElevationService'
    )

    foreach ($serviceName in $edgeServices) {
        $service = Get-Service -Name $serviceName -EA 0
        if ($service) {
            Stop-Service -Name $serviceName -Force -EA 0
            sc.exe delete $serviceName > $null 2>&1
        }
    }
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Status "This script must be run as Administrator" -Level Error
    exit 1
}

if ($UninstallEdge) {
    Write-Status "Starting Microsoft Edge removal..." -Level Success

    Stop-EdgeProcesses
    Remove-EdgeSetup
    Remove-EdgeAppX
    Remove-EdgeRegistry
    Remove-EdgeScheduledTasks
    Remove-EdgeServices
    Remove-EdgeFiles

    Write-Status "Microsoft Edge removal completed!" -Level Success
}

if ($RemoveEdgeData) {
    Write-Status "Removing Edge user data..."

    Stop-EdgeProcesses

    $edgeDataPaths = @(
        "$localAppData\Microsoft\Edge",
        "$localAppData\Microsoft\EdgeUpdate"
    )

    foreach ($dataPath in $edgeDataPaths) {
        if (Test-Path $dataPath) {
            Remove-Item -Path $dataPath -Recurse -Force -EA 0
        }
    }

    Write-Status "Edge user data removed" -Level Success
}

if (!$NonInteractive) {
    Write-Output "`nPress Enter to exit..."
    Read-Host
}
