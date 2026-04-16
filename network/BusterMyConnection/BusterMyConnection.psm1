Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Invoke-BusterConnectivity {
    param(
        [int]$ProxyPort = 3128,
        [int]$TimeoutSeconds = 5,
        [switch]$Silent
    )

    function Set-Proxy {
        $proxy = "http://127.0.0.1:$ProxyPort"
        foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
            [Environment]::SetEnvironmentVariable($k, $proxy, 'Process')
        }
        [Environment]::SetEnvironmentVariable('NO_PROXY','localhost,127.0.0.1','Process')
    }

    function Clear-Proxy {
        Get-ChildItem Env: |
            Where-Object { $_.Name -match '(?i)proxy' } |
            ForEach-Object {
                [Environment]::SetEnvironmentVariable($_.Name,$null,'Process')
            }
    }

    function Test-Direct {
        try {
            Invoke-WebRequest https://www.microsoft.com -UseBasicParsing -TimeoutSec $TimeoutSeconds | Out-Null
            return $true
        } catch { return $false }
    }

    function Test-Proxy {
        try {
            Invoke-WebRequest https://httpbin.org/get -Proxy "http://127.0.0.1:$ProxyPort" `
                -UseBasicParsing -TimeoutSec $TimeoutSeconds | Out-Null
            return $true
        } catch { return $false }
    }

    if (Test-Path "$env:LOCALAPPDATA\Programs\CNTLM\cntlm.exe") {
        Start-Process "$env:LOCALAPPDATA\Programs\CNTLM\cntlm.exe" -WindowStyle Hidden
        Start-Sleep 2
        if (Test-Proxy) {
            Set-Proxy
            return @{ Mode='Proxy'; Success=$true }
        }
    }

    Clear-Proxy
    if (Test-Direct) {
        return @{ Mode='Direct'; Success=$true }
    }

    return @{ Mode='None'; Success=$false }
}

Export-ModuleMember -Function Invoke-BusterConnectivity