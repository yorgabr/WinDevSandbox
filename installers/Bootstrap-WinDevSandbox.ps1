<#
.SYNOPSIS
    Bootstraps the WinDevSandbox PowerShell toolchain on Windows.

.DESCRIPTION
    Bootstrap-WinDevSandbox orchestrates the installation and validation of the
    PowerShell development toolchain provided by the WinDevSandbox project.

    This script acts as the single entry point for preparing a reproducible
    Windows PowerShell development environment, similar in spirit to `tox`
    in the Python ecosystem.

    Responsibilities:
      - Invoke WinDevSandbox installers in a deterministic order
      - Fail fast if any required tool cannot be installed or validated
      - Avoid duplicating installation logic (delegates to installers)
      - Remain safe for corporate environments (proxy, OneDrive, PS 5.1)

    This script intentionally does NOT:
      - Install project dependencies
      - Modify global system state
      - Assume administrator privileges
#>

[CmdletBinding()]
param(
    # Root directory of WinDevSandbox (defaults to script location)
    [string]$SandboxRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),

    # Skip optional tools if needed
    [switch]$SkipInvokeBuild,
    [switch]$SkipPester,
    [switch]$SkipScriptAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#--------------------------------------------------
# Logging helpers
#--------------------------------------------------
function Info    { param($m) Write-Host "[INFO] $m" }
function Success { param($m) Write-Host "[SUCCESS] $m" }
function Warn    { param($m) Write-Warning $m }

#--------------------------------------------------
# Resolve installers directory
#--------------------------------------------------
$InstallersPath = Join-Path $SandboxRoot 'installers'

if (-not (Test-Path -LiteralPath $InstallersPath)) {
    throw "Installers directory not found at: $InstallersPath"
}

Info "Bootstrapping WinDevSandbox environment"
Info "Sandbox root: $SandboxRoot"
Info "Installers directory: $InstallersPath"

#--------------------------------------------------
# Helper: invoke installer safely
#--------------------------------------------------
function Invoke-Installer {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptName
    )

    $scriptPath = Join-Path $InstallersPath $ScriptName

    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Installer not found: $scriptPath"
    }

    Info "Running installer: $ScriptName"
    & $scriptPath
    Success "Installer completed: $ScriptName"
}

#--------------------------------------------------
# Bootstrap sequence (deterministic)
#--------------------------------------------------
Info "Starting WinDevSandbox bootstrap sequence..."

if (-not $SkipPester) {
    Invoke-Installer 'Install-PesterLatest.ps1'
}
else {
    Warn "Skipping Pester installation."
}

if (-not $SkipInvokeBuild) {
    Invoke-Installer 'Install-InvokeBuild.ps1'
}
else {
    Warn "Skipping Invoke-Build installation."
}

if (-not $SkipScriptAnalyzer) {
    Invoke-Installer 'Install-PSScriptAnalyzer.ps1'
}
else {
    Warn "Skipping PSScriptAnalyzer installation."
}

#--------------------------------------------------
# Final sanity checks (lightweight, authoritative)
#--------------------------------------------------
Info "Performing final sanity checks..."

if (-not $SkipPester) {
    try {
        Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop
        Success "Pester is available."
    }
    catch {
        throw "Pester validation failed after WinDevSandbox bootstrap."
    }
}

if (-not $SkipInvokeBuild) {
    if (-not (Get-Command Invoke-Build -ErrorAction SilentlyContinue)) {
        throw "Invoke-Build is not available after WinDevSandbox bootstrap."
    }
    Success "Invoke-Build is available."
}

if (-not $SkipScriptAnalyzer) {
    try {
        Import-Module PSScriptAnalyzer -ErrorAction Stop
        Success "PSScriptAnalyzer is available."
    }
    catch {
        throw "PSScriptAnalyzer validation failed after WinDevSandbox bootstrap."
    }
}

Success "WinDevSandbox bootstrap completed successfully."