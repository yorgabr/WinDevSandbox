<#
.SYNOPSIS
    Bootstraps the WinDevSandbox PowerShell toolchain on Windows.

.DESCRIPTION
    Bootstrap-WinDevSandbox is the single entry point for preparing a
    reproducible PowerShell development environment on Windows.

    It orchestrates network bootstrap and tool installation in a
    deterministic and corporate-safe manner.
#>

[CmdletBinding()]
param(
    [string]$SandboxRoot = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [switch]$SkipPester,
    [switch]$SkipInvokeBuild,
    [switch]$SkipScriptAnalyzer
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Info    { param($m) Write-Host "[INFO] $m" }
function Success { param($m) Write-Host "[SUCCESS] $m" }
function Warn    { param($m) Write-Warning $m }

Info "Bootstrapping WinDevSandbox environment"
Info "Sandbox root: $SandboxRoot"

# --------------------------------------------------
# Network bootstrap (authoritative)
# --------------------------------------------------
$BusterPath = Join-Path $SandboxRoot 'network\Buster-MyConnection.ps1'

if (-not (Test-Path -LiteralPath $BusterPath)) {
    throw "Network bootstrap not found: $BusterPath"
}

Info "Establishing network connectivity..."
& $BusterPath

if ($LASTEXITCODE -ne 0) {
    throw "Network bootstrap failed. Aborting WinDevSandbox bootstrap."
}

Success "Network connectivity established."

# --------------------------------------------------
# Installers
# --------------------------------------------------
$InstallersPath = Join-Path $SandboxRoot 'installers'

function Invoke-Installer {
    param([string]$Name)
    $path = Join-Path $InstallersPath $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Installer not found: $path"
    }
    Info "Running installer: $Name"
    & $path
    Success "Installer completed: $Name"
}

if (-not $SkipPester) {
    Invoke-Installer 'Install-PesterLatest.ps1'
}

if (-not $SkipInvokeBuild) {
    Invoke-Installer 'Install-InvokeBuild.ps1'
}

if (-not $SkipScriptAnalyzer) {
    Invoke-Installer 'Install-PSScriptAnalyzer.ps1'
}

Success "WinDevSandbox bootstrap completed successfully."
