[CmdletBinding()]
param(
    [ValidateSet('install','uninstall','status')]
    [string]$Action = 'install'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProfilePath = $PROFILE.CurrentUserAllHosts
$Marker      = '# WinDevSandbox network bootstrap'
$Line        = "Import-Module '$PSScriptRoot\BusterMyConnection.psd1'; Invoke-BusterConnectivity -Silent | Out-Null"

function Ensure-ProfileExists {
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }
}

switch ($Action) {

    'install' {
        Ensure-ProfileExists

        if (Select-String -Path $ProfilePath -Pattern $Marker -Quiet) {
            Write-Host "Buster already installed in profile."
            return
        }

        Add-Content $ProfilePath @"
$Marker
$Line
"@
        Write-Host "Buster installed into PowerShell profile."
    }

    'uninstall' {
        if (-not (Test-Path $ProfilePath)) { return }

        $content = Get-Content $ProfilePath |
            Where-Object { $_ -notmatch 'WinDevSandbox network bootstrap' } |
            Where-Object { $_ -notmatch 'Invoke-BusterConnectivity' }

        Set-Content $ProfilePath $content
        Write-Host "Buster removed from PowerShell profile."
    }

    'status' {
        if (Test-Path $ProfilePath -and
            Select-String -Path $ProfilePath -Pattern $Marker -Quiet) {
            Write-Host "Buster is ACTIVE in PowerShell profile."
        }
        else {
            Write-Host "Buster is NOT installed in PowerShell profile."
        }
    }
}