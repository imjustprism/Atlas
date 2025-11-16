param (
	[Parameter( Mandatory = $True )]
	[string]$FilePath
)

if (Test-Path $FilePath) { exit }

$content = [System.Text.StringBuilder]::new()
[void]$content.AppendLine("Windows Registry Editor Version 5.00")

$servicesKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("SYSTEM\CurrentControlSet\Services")
foreach ($serviceName in $servicesKey.GetSubKeyNames()) {
	try {
		$serviceKey = $servicesKey.OpenSubKey($serviceName)
		$start = $serviceKey.GetValue('Start')
		$description = $serviceKey.GetValue('Description')
		$serviceKey.Close()

		if ($null -ne $start -and $null -ne $description -and $description -notmatch 'Windows Defender') {
			[void]$content.AppendLine()
			[void]$content.AppendLine("[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\$serviceName]")
			[void]$content.AppendLine('"Start"=dword:0000000' + $start)
		} elseif ($description -match 'Windows Defender') {
			Write-Output "Excluding $serviceName..."
		}
	} catch {}
}
$servicesKey.Close()

[System.IO.File]::WriteAllText($FilePath, $content.ToString(), (New-Object System.Text.UTF8Encoding $false))
