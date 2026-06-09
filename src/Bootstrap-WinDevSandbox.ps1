<#
.SYNOPSIS
    Bootstraps the WinDevSandbox PowerShell toolchain on Windows.

.DESCRIPTION
    Single entry point for two concerns:

    1. TOOLCHAIN SETUP
       Installs Pester, Invoke-Build and PSScriptAnalyzer into the current
       user profile without requiring administrator rights.

    2. SCRIPT AUTO-UPDATE (optional)
       When -SharedScriptsPath is supplied, Install-UserScripts copies all
       scripts from the team shared folder to the user's local bin directory
       and ensures that directory is on PATH. Re-running Bootstrap with the
       same shared path acts as a pull-based update: -Force overwrites any
       script that the team has published since the last run.

.PARAMETER SandboxRoot
    Root of the WinDevSandbox repository. Defaults to the folder containing
    this script.

.PARAMETER SharedScriptsPath
    UNC or local path to the team shared folder that contains the scripts to
    distribute. When omitted, the Install-UserScripts step is skipped.

.PARAMETER SkipPester
    Skip installing Pester.

.PARAMETER SkipInvokeBuild
    Skip installing Invoke-Build.

.PARAMETER SkipScriptAnalyzer
    Skip installing PSScriptAnalyzer.

.PARAMETER SkipUserScripts
    Skip the Install-UserScripts step even when -SharedScriptsPath is set.

.EXAMPLE
    # First-time toolchain setup only
    .\Bootstrap-WinDevSandbox.ps1

.EXAMPLE
    # Toolchain setup + pull latest scripts from the team share
    .\Bootstrap-WinDevSandbox.ps1 -SharedScriptsPath '\\server\team\scripts'

.EXAMPLE
    # Auto-update only (toolchain already installed)
    .\Bootstrap-WinDevSandbox.ps1 -SkipPester -SkipInvokeBuild -SkipScriptAnalyzer `
                                   -SharedScriptsPath '\\server\team\scripts'
#>

[CmdletBinding()]
param(
    [string]$SandboxRoot       = (Split-Path -Parent $MyInvocation.MyCommand.Path),
    [string]$SharedScriptsPath = '',
    [switch]$SkipPester,
    [switch]$SkipInvokeBuild,
    [switch]$SkipScriptAnalyzer,
    [switch]$SkipUserScripts
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
#--------------------------------------------------
Info "Unblocking repository scripts..."
Get-ChildItem -Path $SandboxRoot -Recurse -Include '*.ps1','*.psm1','*.psd1' -File |
    ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }
Success "Scripts unblocked."

#--------------------------------------------------
# Network bootstrap
#--------------------------------------------------
$BusterModule = Join-Path $SandboxRoot 'network\BusterMyConnection.psd1'

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

#--------------------------------------------------
# Installer helper
#--------------------------------------------------
$InstallersPath = Join-Path $SandboxRoot 'installers'

function Invoke-Installer {
    param(
        [string]$Name,
        [hashtable]$Params = @{}
    )
    $path = Join-Path $InstallersPath $Name
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Installer not found: $path"
    }
    Info "Running installer: $Name"
    & $path @Params
    Success "Installer completed: $Name"
}

#--------------------------------------------------
# Toolchain installers
#--------------------------------------------------
if (-not $SkipPester) {
    Invoke-Installer 'Install-PesterLatest.ps1'
}

if (-not $SkipInvokeBuild) {
    Invoke-Installer 'Install-InvokeBuild.ps1'
}

if (-not $SkipScriptAnalyzer) {
    Invoke-Installer 'Install-PSScriptAnalyzer.ps1'
}

#--------------------------------------------------
# Script auto-update from shared folder
#   Copies every script from $SharedScriptsPath to the user's local bin
#   and ensures that bin is on the user's PATH.
#   Re-running with -Force silently overwrites older local copies,
#   acting as a lightweight pull-based update mechanism.
#--------------------------------------------------
if (-not $SkipUserScripts -and -not [string]::IsNullOrWhiteSpace($SharedScriptsPath)) {

    if (-not (Test-Path -LiteralPath $SharedScriptsPath)) {
        throw "Shared scripts path not found: $SharedScriptsPath"
    }

    Info "Updating user scripts from: $SharedScriptsPath"

    Invoke-Installer 'Install-UserScripts.ps1' -Params @{
        SourcePath = $SharedScriptsPath
        Force      = $true
    }
}

Success "WinDevSandbox bootstrap completed successfully."