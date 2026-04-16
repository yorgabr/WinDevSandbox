<#
.SYNOPSIS
    Network connectivity bootstrap for WinDevSandbox.

.DESCRIPTION
    Buster-MyConnection is the authoritative network bootstrap component
    of WinDevSandbox. It ensures outbound connectivity in corporate Windows
    environments by preferring CNTLM-based proxy access and falling back to
    direct internet access when necessary.

    This script is designed to be consumed by WinDevSandbox bootstrap and
    installers. It is not intended to be used as a standalone end-user tool.

    Exit codes:
      0  - Connectivity established (proxied or direct)
      >0 - No usable connectivity strategy available
#>

[CmdletBinding()]
param(
    [string]$IniPath = (Join-Path -Path $HOME -ChildPath 'cntlm.ini'),
    [string]$CntlmPath = (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs/CNTLM/cntlm.exe'),
    [switch]$KeepExisting,
    [switch]$Quiet,
    [switch]$JustCheck,
    [int]$ProxyTestTimeoutSeconds = 5,
    [int]$DirectAccessTestTimeoutSeconds = 10,
    [int]$CheckTimeoutSeconds = 30,
    [int]$CheckRetries = 2
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------
# Metadata
# ------------------------------
$SCRIPT_NAME    = 'Buster-MyConnection'
$SCRIPT_VERSION = '2.2.1'

# ------------------------------
# Output helpers
# ------------------------------
function Out-Info    { param($m) if (-not $Quiet) { Write-Host "[INFO] $m" } }
function Out-Warn    { param($m) if (-not $Quiet) { Write-Warning $m } }
function Out-Success { param($m) Write-Host "[SUCCESS] $m" }
function Out-Error   { param($m) Write-Error $m }

# ------------------------------
# Proxy environment helpers
# ------------------------------
function Backup-ProxyEnvironmentVariables {
    $backup = @{}
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)proxy' } |
        ForEach-Object { $backup[$_.Key] = $_.Value }
    return $backup
}

function Remove-ProxyEnvironmentVariables {
    Get-ChildItem Env: | Where-Object { $_.Key -match '(?i)proxy' } |
        ForEach-Object { Remove-Item "Env:\$($_.Key)" -ErrorAction SilentlyContinue }
}

function Restore-ProxyEnvironmentVariables {
    param($Variables)
    if (-not $Variables) { return }
    foreach ($p in $Variables.PSObject.Properties) {
        if ($null -ne $p.Value) {
            [System.Environment]::SetEnvironmentVariable($p.Name, $p.Value, 'Process')
        }
    }
}

function Set-ProxyEnvironmentForCntlm {
    param([int]$Port)
    $proxy = "http://127.0.0.1:$Port"
    [System.Environment]::SetEnvironmentVariable('HTTP_PROXY',  $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('ALL_PROXY',   $proxy, 'Process')
    [System.Environment]::SetEnvironmentVariable('NO_PROXY',    'localhost,127.0.0.1', 'Process')
}

# ------------------------------
# Connectivity tests
# ------------------------------
function Test-InternetConnectivity {
    param([int]$TimeoutSeconds)
    foreach ($url in @(
        'http://httpbin.org/get',
        'https://httpbin.org/get',
        'https://www.microsoft.com/'
    )) {
        try {
            Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
            return $true
        } catch {}
    }
    return $false
}

function Test-ProxyConnectivity {
    param([int]$Port,[int]$TimeoutSeconds)
    $proxy = "http://127.0.0.1:$Port"
    foreach ($url in @(
        'http://httpbin.org/get',
        'https://httpbin.org/get'
    )) {
        try {
            Invoke-WebRequest -Uri $url -Proxy $proxy -TimeoutSec $TimeoutSeconds -UseBasicParsing | Out-Null
        } catch { return $false }
    }
    return $true
}

# ------------------------------
# Main flow
# ------------------------------
Out-Info "Evaluating CNTLM availability (primary strategy)..."

if (Test-Path $CntlmPath) {
    Start-Process -FilePath $CntlmPath -ArgumentList @('-c', $IniPath) -WindowStyle Hidden
    Start-Sleep -Seconds 2

    if (Test-ProxyConnectivity -Port 3128 -TimeoutSeconds $ProxyTestTimeoutSeconds) {
        Set-ProxyEnvironmentForCntlm -Port 3128
        Out-Success "PROXY MODE active."
        exit 0
    }
}

Out-Warn "CNTLM unavailable. Falling back to direct access."
Remove-ProxyEnvironmentVariables

if (Test-InternetConnectivity -TimeoutSeconds $DirectAccessTestTimeoutSeconds) {
    Out-Success "DIRECT ACCESS active."
    exit 0
}

Out-Error "No usable connectivity strategy available."
exit 1