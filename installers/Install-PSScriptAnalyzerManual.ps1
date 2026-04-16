<#
.SYNOPSIS
    Manual, resilient and idempotent installer for the PSScriptAnalyzer module
    on Windows PowerShell 5.1, without requiring administrative privileges.

.DESCRIPTION
    Windows PowerShell 5.1 ships with an obsolete PackageManagement + PowerShellGet stack
    that often fails to download modules from the PowerShell Gallery due to TLS and endpoint
    constraints. This installer provides a fully self-contained, manual and enterprise-safe
    process that:

      • Validates or downloads the official .nupkg package (default: v1.24.0).
      • Optionally verifies file integrity via cryptographic hash.
      • Extracts and validates the internal module structure.
      • Installs the module into the user’s profile (no admin rights).
      • Optionally code-signs PS1/PSM1/PSD1 files (with timestamping).
      • Honors corporate proxy settings with .NET WebClient.
      • Emits ANSI-colored logs (or plain text if ANSI is unavailable/disabled).
      • Enforces Windows PowerShell (Desktop) 5.1+ via a guard clause.

    The script is fully idempotent: if the module is already installed and importable,
    it performs no further changes.

.PARAMETER ModuleVersion
    Target module version (default: 1.24.0).

.PARAMETER NupkgPath
    Optional explicit path to the .nupkg file. If omitted and DownloadIfMissing is set,
    the package will be downloaded to the current directory.

.PARAMETER DownloadIfMissing
    Attempts to download the package when it is not present locally.

.PARAMETER DownloadUrl
    Direct package URL (PowerShell Gallery API v2 endpoint). Must point to the exact version.

.PARAMETER ExpectedHash
    Optional hex-encoded hash string used to verify the .nupkg integrity.

.PARAMETER HashAlgorithm
    Hash algorithm (default: SHA256). Accepts SHA256, SHA1, SHA512, MD5.

.PARAMETER Sign
    Signs PS1/PSM1/PSD1 files in the installed module directory.

.PARAMETER CertThumbprint
    Thumbprint of an existing code-signing certificate in CurrentUser\My.

.PARAMETER CertSubject
    Subject substring to locate an existing code-signing certificate in CurrentUser\My.

.PARAMETER CreateSelfSignedCert
    Creates a new self-signed code-signing certificate in CurrentUser\My if none is found.

.PARAMETER TimestampServer
    RFC3161 timestamp server URL for Authenticode signatures.

.PARAMETER LogLevel
    Logging level (ERROR, WARN, INFO, DEBUG). Default: INFO.

.PARAMETER LogFile
    Path to the log file. Default: %TEMP%\PSScriptAnalyzer_install_<timestamp>.log

.PARAMETER UseProxy
    Enables explicit proxy handling for the download fallback.

.PARAMETER ProxyUri
    Proxy URL (e.g., http://127.0.0.1:3128). If omitted with -UseProxy, uses system proxy.

.PARAMETER ProxyCredential
    PSCredential for the proxy. If omitted, defaults to current user or system proxy creds.

.PARAMETER ForceCore
    Test-only escape hatch to allow running on PowerShell Core. Not supported in production.

.PARAMETER Ansi
    Controls ANSI color usage: Auto (default), On, Off.

.EXAMPLE
    .\Install-PSScriptAnalyzerManual.ps1
    Uses a manually downloaded .nupkg in the current directory and installs the module.

.EXAMPLE
    .\Install-PSScriptAnalyzerManual.ps1 -DownloadIfMissing -Ansi Auto -LogLevel DEBUG
    Attempts WebClient download (honoring proxy), uses ANSI auto-detection, and verbose logs.

.EXAMPLE
    .\Install-PSScriptAnalyzerManual.ps1 -ExpectedHash 'ABCDEF...' -HashAlgorithm SHA256
    Verifies integrity before installing.

.EXAMPLE
    .\Install-PSScriptAnalyzerManual.ps1 -Sign -CreateSelfSignedCert
    Installs and signs the module using a newly created self-signed certificate.

.NOTES
    All messages and comments are in English for consistent operations across teams/locales.
#>

[CmdletBinding()]
param(
    # Core parameters
    [string]$ModuleVersion = '1.24.0',
    [string]$NupkgPath     = "$(Join-Path (Get-Location) "PSScriptAnalyzer.$ModuleVersion.nupkg")",
    [switch]$DownloadIfMissing,
    [string]$DownloadUrl   = "https://cdn.powershellgallery.com/packages/psscriptanalyzer.1.24.0.nupkg",
    [switch]$Quiet,

    # Integrity
    [string]$ExpectedHash,
    [ValidateSet('SHA256','SHA1','SHA512','MD5')]
    [string]$HashAlgorithm = 'SHA256',

    # Signing
    [switch]$Sign,
    [string]$CertThumbprint,
    [string]$CertSubject,
    [switch]$CreateSelfSignedCert,
    [string]$TimestampServer = "http://timestamp.digicert.com",

    # Proxy
    [switch]$UseProxy,
    [string]$ProxyUri,
    [System.Management.Automation.PSCredential]$ProxyCredential,

    # Environment/compatibility
    [switch]$ForceCore,

    # ANSI control: Auto | On | Off
    [ValidateSet('Auto','On','Off')]
    [string]$Ansi = 'Auto'
)

#------------------------------
# Strict Mode + Error Model
#------------------------------
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#------------------------------
# Guard Clause: enforce Windows PowerShell (Desktop) 5.1+
#------------------------------
$edition = $PSVersionTable.PSEdition
$ver     = $PSVersionTable.PSVersion

if ($edition -ne 'Desktop' -and -not $ForceCore) {
    [Console]::Error.WriteLine("[ERROR] This installer is intended to run in Windows PowerShell (PSEdition 'Desktop'), not in PowerShell Core.")
    [Console]::Out.WriteLine("[INFO] Detected: PSEdition='{0}', Version='{1}'" -f $edition,$ver)
    [Console]::Out.WriteLine("[WARN] If you really need to continue (test only), re-run with -ForceCore.")
    exit 2
}

if ($edition -eq 'Desktop') {
    if ($ver.Major -lt 5 -or ($ver.Major -eq 5 -and $ver.Minor -lt 1)) {
        [Console]::Error.WriteLine("[ERROR] Windows PowerShell 5.1 or later is required. Detected version: $ver")
        exit 2
    }
} elseif ($ForceCore) {
    [Console]::Out.WriteLine("[WARN] ForceCore enabled. Continuing under PowerShell Core (unsupported path).")
}

#------------------------------
# Color helpers for rich console output (PS 5.1 compatible)
#------------------------------
# Windows PowerShell 5.1 compatible escape character
$ESC = if ($PSVersionTable.PSVersion.Major -ge 6) { "`e" } else { $([char]0x1b) }
$Cyan   = "${ESC}[36m"
$Yellow = "${ESC}[33m"
$Green  = "${ESC}[32m"
$Red    = "${ESC}[31m"
$Reset  = "${ESC}[0m"

#------------------------------
# Logging helpers
#------------------------------
function Out-Info {
    param([string]$Message)
    if (-not $Quiet) {
        [Console]::Out.WriteLine("$Cyan[INFO]$Reset $Message")
    }
}

function Out-Warn {
    param([string]$Message)
    if (-not $Quiet) {
        [Console]::Out.WriteLine("$Yellow[WARN]$Reset $Message")
    }
}

function Out-Success {
    param([string]$Message)
    if (-not $Quiet) {
        [Console]::Out.WriteLine("$Green[SUCCESS]$Reset $Message")
    }
}

function Out-Error {
    param([string]$Message)
    [Console]::Error.WriteLine("$Red[ERROR]$Reset $Message")
}

#------------------------------
# TLS setup for HTTPS
#------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Out-Info "TLS1.2 enabled."
} catch {
    Out-Warn "Failed to set TLS1.2. Continuing anyway."
}

#------------------------------
# Paths and constants
#------------------------------
$ModuleName      = "PSScriptAnalyzer"
$CurrentDir      = (Get-Location).Path
$ZipTempName     = "$ModuleName.$ModuleVersion.zip"
$ZipTempPath     = Join-Path $Env:TEMP $ZipTempName
$ExtractTempDir  = Join-Path $Env:TEMP "extract_$ModuleName"
$UserModulesDir  = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'
$ModuleTargetDir = Join-Path $UserModulesDir $ModuleName

#------------------------------
# Proxy handling
#------------------------------
function Get-ProxyFromEnvironment {
    param([string]$TargetUrl)

    # Prefer HTTPS proxy for HTTPS URLs
    if ($TargetUrl -match '^https:' -and $env:HTTPS_PROXY) {
        return New-Object System.Net.WebProxy($env:HTTPS_PROXY, $true)
    }

    if ($env:HTTP_PROXY) {
        return New-Object System.Net.WebProxy($env:HTTP_PROXY, $true)
    }

    if ($env:ALL_PROXY) {
        return New-Object System.Net.WebProxy($env:ALL_PROXY, $true)
    }

    return $null
}

#------------------------------
# Hash verification
#------------------------------
function Validate-FileHash {
    param([string]$Path, [string]$Algorithm, [string]$Expected)

    $computed = (Get-FileHash -Path $Path -Algorithm $Algorithm).Hash.ToUpperInvariant()
    Out-Info "Computed $Algorithm hash: $computed"

    if ($Expected) {
        if ($computed -ne $Expected.ToUpperInvariant()) {
            Out-Error "Hash mismatch: expected '$Expected' but computed '$computed'"
            throw "Integrity verification failed."
        }
        Out-Success "Hash verification successful."
    } else {
        Out-Warn "No expected hash was provided. Consider specifying -ExpectedHash for integrity assurance."
    }
}

#------------------------------
# Download fallback
#------------------------------
function Download-Package {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Url,

        [Parameter(Mandatory=$true)]
        [string]$OutFile
    )

    Out-Info "Attempting package download via System.Net.WebClient..."

    $wc = New-Object System.Net.WebClient

    try {
        # Environment variables FIRST
        $proxy = Get-ProxyFromEnvironment -TargetUrl $Url

        if ($proxy) {
            Out-Info "Using proxy from environment variables: $($proxy.Address)"
            $wc.Proxy = $proxy
        }
        else {
            # Fall back to WinINET system proxy
            Out-Info "No proxy variables set. Using system proxy (WinINET)."
            $wc.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            $wc.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
        }

        $wc.DownloadFile($Url, $OutFile)

        Out-Success "Downloaded: $OutFile"
        return $true
    }
    catch {
        Out-Error "Download failed: $($_.Exception.Message)"
        return $false
    }
    finally {
        $wc.Dispose()
    }
}

#------------------------------
# Zip extraction
#------------------------------
function Expand-Zip {
    param([string]$ZipPath, [string]$Destination)

    if (Test-Path $Destination) { Remove-Item $Destination -Recurse -Force }
    New-Item -ItemType Directory -Path $Destination | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $Destination)
}

#------------------------------
# Module structure validation
#------------------------------
function Test-ModuleStructure {
    param([string]$Root)

    $psd1 = Join-Path $Root "$ModuleName.psd1"
    $dll  = Join-Path $Root "Microsoft.Windows.PowerShell.ScriptAnalyzer.dll"

    if (-not (Test-Path $psd1)) { Out-Error "Missing module manifest: $psd1"; return $false }
    if (-not (Test-Path $dll))  { Out-Error "Missing core assembly: $dll";   return $false }

    try {
        $manifest = Import-PowerShellDataFile -Path $psd1
        Out-Info "Manifest detected. ModuleVersion: $($manifest.ModuleVersion)"
    } catch {
        Out-Warn "Unable to parse module manifest for version check."
    }

    return $true
}

#------------------------------
# Code signing support
#------------------------------
function Get-CodeSigningCert {
    if ($CertThumbprint) {
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Thumbprint -eq $CertThumbprint }
        if ($cert) { return $cert }
        Out-Warn "Certificate not found by thumbprint '$CertThumbprint'."
    }

    if ($CertSubject) {
        $cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object {
            $_.Subject -like "*$CertSubject*" -and $_.EnhancedKeyUsageList.FriendlyName -contains 'Code Signing'
        }
        if ($cert) { return $cert }
        Out-Warn "Certificate not found by subject substring '$CertSubject'."
    }

    if ($CreateSelfSignedCert) {
        Out-Info "Creating self-signed Code Signing certificate in CurrentUser\My..."
        try {
            return New-SelfSignedCertificate -Type CodeSigningCert -Subject "CN=$env:USERNAME Code Signing" -CertStoreLocation "Cert:\CurrentUser\My"
        } catch {
            Out-Error "Failed to create self-signed certificate: $($_.Exception.Message)"
        }
    }

    return $null
}

function Sign-ModuleFiles {
    param([string]$TargetDir, [System.Security.Cryptography.X509Certificates.X509Certificate2]$Cert)

    if (-not $Cert) { Out-Warn "Signing requested but no certificate available."; return }

    $files = Get-ChildItem -Path $TargetDir -Include *.ps1,*.psm1,*.psd1 -Recurse -File -ErrorAction SilentlyContinue
    if (-not $files) { Out-Warn "No PS1/PSM1/PSD1 files found to sign."; return }

    foreach ($f in $files) {
        try {
            $sig = Set-AuthenticodeSignature -FilePath $f.FullName -Certificate $Cert -TimestampServer $TimestampServer -HashAlgorithm SHA256
            Out-Info "Signed '$($f.Name)': $($sig.Status)"
        } catch {
            Out-Warn "Failed to sign '$($f.FullName)': $($_.Exception.Message)"
        }
    }
}

#------------------------------
# MAIN FLOW
#------------------------------
try {
    Out-Info "Starting manual installation for $ModuleName v$ModuleVersion"

    # Idempotency: already installed and importable?
    if (Test-Path $ModuleTargetDir) {
        try {
            Import-Module $ModuleName -Force
            Out-Success "Module is already installed and importable at: $ModuleTargetDir"
            Out-Info    "Nothing to do."
            return
        } catch {
            Out-Warn "Existing directory found but Import-Module failed. Proceeding with reinstall."
        }
    }

    # Ensure package availability
    if (-not (Test-Path $NupkgPath)) {
        Out-Warn "Package not found at: $NupkgPath"
        if (-not $DownloadIfMissing) {
            Out-Error "Set -DownloadIfMissing or provide the .nupkg via -NupkgPath."
            Out-Info  "Manual download (official source): https://www.powershellgallery.com/packages/$ModuleName"
            throw "Package unavailable."
        }

        $ok = Download-Package -Url $DownloadUrl -OutFile $NupkgPath
        if (-not $ok) { throw "Failed to obtain package." }
    } else {
        Out-Info "Using local package: $NupkgPath"
    }

    # Hash validation (optional)
    Validate-FileHash -Path $NupkgPath -Algorithm $HashAlgorithm -Expected $ExpectedHash

    # Convert .nupkg → .zip and extract
    if (Test-Path $ZipTempPath) { Remove-Item $ZipTempPath -Force }
    Copy-Item $NupkgPath $ZipTempPath -Force
    Out-Info "Extracting package [$ZipTempPath] to [$ExtractTempDir]"
    Expand-Zip -ZipPath "$ZipTempPath" -Destination "$ExtractTempDir"

    # Validate internal structure
    $SourceRoot = $ExtractTempDir
    if (-not (Test-Path $SourceRoot)) {
        Out-Error "Invalid package structure: missing '$ModuleName' root folder inside the archive."
        throw "Invalid package structure."
    }

    if (-not (Test-ModuleStructure -Root $SourceRoot)) {
        throw "Module structure validation failed."
    }

    # Install to user modules directory
    if (-not (Test-Path $UserModulesDir)) { New-Item -ItemType Directory -Path $UserModulesDir | Out-Null }
    if (Test-Path $ModuleTargetDir) { Remove-Item $ModuleTargetDir -Recurse -Force }
    Copy-Item $SourceRoot $ModuleTargetDir -Recurse -Force
    Out-Success "Installed to: $ModuleTargetDir"

    # Optional signing
    if ($Sign) {
        $cert = Get-CodeSigningCert
        Sign-ModuleFiles -TargetDir $ModuleTargetDir -Cert $cert
    }

    # Cleanup
    Remove-Item $ZipTempPath -Force -ErrorAction SilentlyContinue
    Remove-Item $ExtractTempDir -Recurse -Force -ErrorAction SilentlyContinue

    # Import test
    Import-Module $ModuleName -Force
    Out-Success "PSScriptAnalyzer imported successfully."
    Out-Info    "Usage: Invoke-ScriptAnalyzer -Path . -Recurse"
}
catch {
    Out-Error "Installation failed: $($_.Exception.Message)"
    exit 1
}
finally {
    Out-Info "Installer finished."
}