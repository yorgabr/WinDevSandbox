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

#--------------------------------------------------
# Unblock all repository scripts
#   Files downloaded from the internet (browser, GitHub ZIP) carry a
#   Zone.Identifier alternate data stream that triggers the PowerShell
#   execution-policy security prompt. Unblocking them here, before any
#   Import-Module call, silences that warning for the entire toolchain.
#--------------------------------------------------
Info "Unblocking repository scripts..."

Get-ChildItem -Path $SandboxRoot -Recurse -Include '*.ps1', '*.psm1', '*.psd1' -File |
    ForEach-Object {
        Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue
    }

Success "Scripts unblocked."

#--------------------------------------------------
# Network bootstrap (authoritative)
#--------------------------------------------------
$BusterModule = Join-Path $SandboxRoot 'network\BusterMyConnection\BusterMyConnection.psd1'

if (-not (Test-Path -LiteralPath $BusterModule)) {
    throw "Buster module not found: $BusterModule"
}

Info "Bootstrapping network connectivity..."
Import-Module $BusterModule -Force

$result = Invoke-BusterConnectivity -Silent

if (-not $result.Success) {
    throw "Network bootstrap failed. Aborting WinDevSandbox bootstrap."
}

Success "Network connectivity established via $($result.Mode)."

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
