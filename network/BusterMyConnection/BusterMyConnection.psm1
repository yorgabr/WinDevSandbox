Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\Network.psm1') -Force


function Invoke-BusterConnectivity {
    param(
        [int]$ProxyPort = 3128,
        [int]$TimeoutSeconds = 5,
        [switch]$Silent
    )

    if (Test-Path "$env:LOCALAPPDATA\Programs\CNTLM\cntlm.exe") {
        Start-Process "$env:LOCALAPPDATA\Programs\CNTLM\cntlm.exe" -WindowStyle Hidden
        Start-Sleep 2
        if (Test-LocalProxy) {
            Set-ProxyEnvironment
            return @{ Mode='Proxy'; Success=$true }
        }
    }

    Clear-ProxyEnvironment
    if (Test-DirectInternet) {
        return @{ Mode='Direct'; Success=$true }
    }

    return @{ Mode='None'; Success=$false }
}

Export-ModuleMember -Function Invoke-BusterConnectivity