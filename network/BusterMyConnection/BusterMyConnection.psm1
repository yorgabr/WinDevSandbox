Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\lib\Network.psm1') -Force

# ---------------------------------------------------------------------------
# Test-DirectConnectivity
#   Thin wrapper around Test-DirectInternet (defined in Network.psm1).
#   Lives at module scope so it can be independently tested and mocked.
# ---------------------------------------------------------------------------
function Test-DirectConnectivity {
    [CmdletBinding()]
    param(
        [int]$TimeoutSeconds = 5
    )

    Test-DirectInternet -TimeoutSeconds $TimeoutSeconds
}

# ---------------------------------------------------------------------------
# Invoke-BusterConnectivity
#   Primary entry point for network bootstrap.
#   Strategy: CNTLM proxy (preferred) → Direct internet → failure.
# ---------------------------------------------------------------------------
function Invoke-BusterConnectivity {
    [CmdletBinding()]
    param(
        [string]$CntlmPath     = (Join-Path $env:LOCALAPPDATA 'Programs\CNTLM\cntlm.exe'),
        [int]   $ProxyPort     = 3128,
        [int]   $TimeoutSeconds = 5,
        [switch]$Silent
    )

    if (-not $Silent) {
        Write-Verbose 'Evaluating connectivity strategies...'
    }

    # ---- Strategy 1: CNTLM proxy ----------------------------------------
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

    # ---- Strategy 2: Direct internet ------------------------------------
    Clear-ProxyEnvironment

    if (Test-DirectConnectivity -TimeoutSeconds $TimeoutSeconds) {
        return @{
            Mode    = 'Direct'
            Success = $true
        }
    }

    # ---- No usable path -------------------------------------------------
    return @{
        Mode    = 'None'
        Success = $false
    }
}

Export-ModuleMember -Function Invoke-BusterConnectivity, Test-DirectConnectivity
