$profilePath = $PROFILE.CurrentUserAllHosts

if (-not (Test-Path $profilePath)) {
    New-Item -ItemType File -Path $profilePath -Force | Out-Null
}

$line = "Import-Module '$PSScriptRoot\BusterMyConnection.psd1'; Invoke-BusterConnectivity -Silent | Out-Null"

if (-not (Select-String -Path $profilePath -Pattern 'Invoke-BusterConnectivity' -Quiet)) {
    Add-Content $profilePath "`n# WinDevSandbox network bootstrap`n$line"
}