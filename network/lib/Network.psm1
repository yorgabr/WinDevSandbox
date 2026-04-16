Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Set-ProxyEnvironment {
    param(
        [Parameter(Mandatory)]
        [string]$ProxyUrl
    )

    foreach ($k in 'HTTP_PROXY','HTTPS_PROXY','ALL_PROXY') {
        [System.Environment]::SetEnvironmentVariable($k, $ProxyUrl, 'Process')
    }

    [System.Environment]::SetEnvironmentVariable(
        'NO_PROXY',
        'localhost,127.0.0.1',
        'Process'
    )
}

function Clear-ProxyEnvironment {
    Get-ChildItem Env: |
        Where-Object { $_.Name -match '(?i)_?proxy$' } |
        ForEach-Object {
            [System.Environment]::SetEnvironmentVariable($_.Name, $null, 'Process')
        }
}

function Test-DirectInternet {
    param([int]$TimeoutSeconds = 5)

    foreach ($url in @(
        'https://www.microsoft.com',
        'https://httpbin.org/get'
    )) {
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
            return $true
        } catch {}
    }

    return $false
}

function Test-LocalProxy {
    param(
        [int]$Port = 3128,
        [int]$TimeoutSeconds = 5
    )

    $proxy = "http://127.0.0.1:$Port"

    try {
        Invoke-WebRequest `
            -Uri 'https://httpbin.org/get' `
            -Proxy $proxy `
            -TimeoutSec $TimeoutSeconds `
            -UseBasicParsing | Out-Null

        return $true
    }
    catch {
        return $false
    }
}

Export-ModuleMember `
    -Function Set-ProxyEnvironment,
              Clear-ProxyEnvironment,
              Test-DirectInternet,
              Test-LocalProxy