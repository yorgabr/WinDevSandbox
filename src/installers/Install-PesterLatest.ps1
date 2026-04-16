<#
.SYNOPSIS
    Installs or repairs the latest Pester version for Windows PowerShell 5.1.

.DESCRIPTION
    Self-healing Pester installer for corporate environments.

    - Uses the official PowerShell Gallery .nupkg (authoritative)
    - Does NOT assume fixed layout inside the nupkg
    - Discovers module base by locating Pester.psd1
    - OneDrive / GPO safe (MyDocuments)
    - Fully idempotent
    - Verifies installation via explicit Import-Module
    - StrictMode-safe, PS 5.1 compatible
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#--------------------------------------------------
# Logging helpers
#--------------------------------------------------
function Info    { param($m) Write-Host "[INFO] $m" }
function Success { param($m) Write-Host "[SUCCESS] $m" }
function Warn    { param($m) Write-Warning $m }

#--------------------------------------------------
# Resolve correct user module root (OneDrive/GPO safe)
#--------------------------------------------------
$DocumentsPath  = [System.Environment]::GetFolderPath('MyDocuments')
$UserModuleRoot = Join-Path $DocumentsPath 'WindowsPowerShell\Modules'
$PesterRoot     = Join-Path $UserModuleRoot 'Pester'

Info "Using user module root: $UserModuleRoot"

#--------------------------------------------------
# Ensure module directories exist
#--------------------------------------------------
foreach ($dir in @($UserModuleRoot, $PesterRoot)) {
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

#--------------------------------------------------
# Discover latest Pester version (metadata only)
#--------------------------------------------------
Info "Discovering latest Pester version..."

try {
    $release = Invoke-RestMethod `
        -Uri 'https://api.github.com/repos/pester/Pester/releases/latest' `
        -Headers @{ 'User-Agent' = 'Install-PesterLatest' } `
        -TimeoutSec 20

    $version = $release.tag_name.TrimStart('v')
}
catch {
    throw "Unable to determine latest Pester version from GitHub API."
}

Info "Latest Pester version detected: $version"

#--------------------------------------------------
# Download official .nupkg from PowerShell Gallery
#--------------------------------------------------
$nupkgUrl = "https://www.powershellgallery.com/api/v2/package/Pester/$version"

$tempNupkg   = Join-Path $env:TEMP "Pester.$version.nupkg"
$tempZip     = Join-Path $env:TEMP "Pester.$version.zip"
$tempExtract = Join-Path $env:TEMP ("pester-nupkg-{0}" -f ([guid]::NewGuid()))

Info "Downloading Pester $version from PowerShell Gallery (.nupkg)..."
Invoke-WebRequest -Uri $nupkgUrl -OutFile $tempNupkg -UseBasicParsing

# PS 5.1 Expand-Archive only supports .zip
Copy-Item -LiteralPath $tempNupkg -Destination $tempZip -Force

Info "Extracting .nupkg (as zip)..."
Expand-Archive -LiteralPath $tempZip -DestinationPath $tempExtract -Force

#--------------------------------------------------
# Locate module base by discovering Pester.psd1
#--------------------------------------------------
$psd1Source = Get-ChildItem -Path $tempExtract -Recurse -Filter 'Pester.psd1' -File |
    Select-Object -First 1

if (-not $psd1Source) {
    throw "Could not locate Pester.psd1 inside extracted nupkg."
}

$moduleSource = Split-Path $psd1Source.FullName -Parent

#--------------------------------------------------
# Target installation path
#--------------------------------------------------
$targetVersionPath = Join-Path $PesterRoot $version
$psd1Target        = Join-Path $targetVersionPath 'Pester.psd1'

#--------------------------------------------------
# Validate existing installation (if present)
#--------------------------------------------------
if (Test-Path -LiteralPath $psd1Target) {
    Info "Existing Pester $version detected. Validating..."

    try {
        Import-Module $psd1Target -Force -ErrorAction Stop
        Success "Existing Pester installation is valid."
        return
    }
    catch {
        Warn "Existing Pester installation is INVALID. Reinstalling..."
        Remove-Item -LiteralPath $targetVersionPath -Recurse -Force
    }
}

#--------------------------------------------------
# Install fresh (copy ModuleBase as-is)
#--------------------------------------------------
Info "Installing Pester $version..."
New-Item -ItemType Directory -Path $targetVersionPath -Force | Out-Null

Copy-Item -Path (Join-Path $moduleSource '*') `
          -Destination $targetVersionPath `
          -Recurse -Force

#--------------------------------------------------
# Final verification (authoritative)
#--------------------------------------------------
Info "Final verification (explicit import)..."

try {
    Import-Module $psd1Target -Force -ErrorAction Stop
    Success "Pester $version successfully installed and importable."
}
catch {
    throw "Installed Pester module failed to import: $($_.Exception.Message)"
}
finally {
    Remove-Item -LiteralPath $tempNupkg   -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempZip     -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
}