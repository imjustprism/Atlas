$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")

if (!$isAdmin) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-File `"$PSCommandPath`""
    exit
}

$windir = [Environment]::GetFolderPath('Windows')
$rootKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SOFTWARE\AtlasOS\Services", $true)
if (!$rootKey) { exit }

function Process-Key {
    param($Key)

    try {
        $path = $Key.GetValue('path')
        if ($path) {
            Write-Output $path
            if ($path -notlike "$windir\AtlasDesktop\*") {
                $marker = "AtlasDesktop\"
                $index = $path.IndexOf($marker)
                if ($index -ge 0) {
                    $result = $path.Substring($index + $marker.Length)
                    $Key.SetValue('path', "$windir\AtlasDesktop\$result")
                }
            }
        }

        foreach ($subKeyName in $Key.GetSubKeyNames()) {
            $subKey = $Key.OpenSubKey($subKeyName, $true)
            if ($subKey) {
                Process-Key $subKey
                $subKey.Close()
            }
        }
    } catch {}
}

Process-Key $rootKey
$rootKey.Close()
