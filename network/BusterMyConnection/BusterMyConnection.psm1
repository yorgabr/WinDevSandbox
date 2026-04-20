Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\Network.psm1') -Force

function Invoke-BusterConnectivity {
    param(
        [string]$CntlmPath = (Join-Path $env:LOCALAPPDATA 'Programs\CNTLM\cntlm.exe'),
        [int]$ProxyPort = 3128,
        [int]$TimeoutSeconds = 5,
        [switch]$Silent
    )

    if (-not $Silent) {
        Write-Verbose 'Evaluating connectivity strategies...'
    }

    # --- Proxy via CNTLM
    if (Test-Path $CntlmPath) {
        Start-Process $CntlmPath -WindowStyle Hidden
        Start-Sleep -Seconds 2

        if (Test-LocalProxy -Port $ProxyPort -TimeoutSeconds $TimeoutSeconds) {
            Set-ProxyEnvironment "http://127.0.0.1:$ProxyPort"

            return @{
                Mode    = 'Proxy'
                Success = $true
            }
        }
    }

    # --- Direct access fallback
    Clear-ProxyEnvironment

    function Test-DirectConnectivity {
        [CmdletBinding()]
        param(
            [int]$TimeoutSeconds
        )

        Test-DirectInternet -TimeoutSeconds $TimeoutSeconds
    }


    return @{
        Mode    = 'None'
        Success = $false
    }
}

Export-ModuleMember -Function Invoke-BusterConnectivity, Test-DirectConnectivity