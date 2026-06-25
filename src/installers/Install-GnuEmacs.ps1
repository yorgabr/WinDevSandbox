<#
.SYNOPSIS
    Idempotent userspace installation script for GNU Emacs 30.2 with Proxy support.
.DESCRIPTION
    This script validates prerequisites, automatically detects session or system proxy configurations,
    downloads the portable version of GNU Emacs, extracts it to the user's local directory, and 
    configures the HOME environment variable. Designed for automation and CI/CD pipelines.
.PARAMETER Version
    Displays the script version in SemVer format and exits.
.PARAMETER Help
    Displays this professional help menu.
.EXAMPLE
    .\Install-GnuEmacs.ps1
.EXAMPLE
    .\Install-GnuEmacs.ps1 -Version
#>
param(
    [switch]$Version,
    [switch]$Help
)

# ---------------------------------------------------------------------
# SCRIPT METADATA & PARAMETER HANDLING
# ---------------------------------------------------------------------
$ScriptVersion = "1.0.0"

if ($Version) {
    Write-Output $ScriptVersion
    exit 0
}

if ($Help) {
    Get-Help $PSCommandPath
    exit 0
}

# ---------------------------------------------------------------------
# LOGGING ENGINE (CI/CD OPTIMIZED)
# ---------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("INFO", "WARN", "ERROR", "SUCCESS")]
        [string]$Level,
        [Parameter(Mandatory=$true)]
        [string]$Message
    )
    $Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
    $Color = switch ($Level) {
        "INFO"    { "Cyan" }
        "WARN"    { "Yellow" }
        "ERROR"   { "Red" }
        "SUCCESS" { "Green" }
    }
    # Standard Structured Logging Format: [YYYY-MM-DD HH:MM:SS] [LEVEL] Message
    Write-Host "[$Timestamp] [$Level] $Message" -ForegroundColor $Color
}

# ---------------------------------------------------------------------
# ASYNC SPINNER ENGINE FOR LONG-RUNNING TASKS
# ---------------------------------------------------------------------
function Invoke-WithSpinner {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$ScriptBlock,
        [Parameter(Mandatory=$true)]
        [string]$StatusMessage
    )
    
    $Spinner = @('|', '/', '-', '\')
    $Task = [PowerShell]::Create().AddScript($ScriptBlock)
    # Share external variables into the threadroom context if needed
    $Task.Runspace.SessionStateProxy.SetVariable('Url', $using:Url)
    $Task.Runspace.SessionStateProxy.SetVariable('ZipPath', $using:ZipPath)
    $Task.Runspace.SessionStateProxy.SetVariable('TargetDir', $using:TargetDir)
    $Task.Runspace.SessionStateProxy.SetVariable('WebParams', $using:WebParams)
    
    $AsyncResult = $Task.BeginInvoke()
    $Counter = 0

    while (-not $AsyncResult.IsCompleted) {
        $Char = $Spinner[$Counter % $Spinner.Count]
        Write-Host "`r[$Char] $StatusMessage..." -NoNewline -ForegroundColor Yellow
        Start-Sleep -Milliseconds 200
        $Counter++
    }
    
    # Clear the spinner line
    Write-Host "`r" -NoNewline
    
    # End invoke and capture exceptions
    try {
        $Task.EndInvoke($AsyncResult)
        if ($Task.Streams.Error.Count -gt 0) {
            throw $Task.Streams.Error[0].Exception
        }
    }
    catch {
        throw $_
    }
    finally {
        $Task.Dispose()
    }
}

# ---------------------------------------------------------------------
# INFRASTRUCTURE PIPELINE CONFIGURATION
# ---------------------------------------------------------------------
$Url        = "https://ftp.gnu.org/gnu/emacs/windows/emacs-30/emacs-30.2-x86_64-installer.zip"
$TargetDir  = "$env:USERPROFILE\Programs\Emacs"
$ZipPath    = "$env:USERPROFILE\Programs\emacs.zip"
$BinaryPath = "$TargetDir\bin\runemacs.exe"

$ProgressPreference = 'SilentlyContinue'

Write-Log "INFO" "Executing GNU Emacs automation deployment pipeline."

# ---------------------------------------------------------------------
# PREREQUISITE ASSESSMENT & PROXY AUTO-DISCOVERY
# ---------------------------------------------------------------------
Write-Log "INFO" "Assessing environment prerequisites and discovering proxy topologies..."

$ProxyUri = $env:https_proxy
if (-not $ProxyUri) { $ProxyUri = $env:http_proxy }
if (-not $ProxyUri) {
    $RegProxy = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction SilentlyContinue
    if ($RegProxy -and $RegProxy.ProxyEnable -eq 1) {
        $ProxyUri = $RegProxy.ProxyServer
    }
}

$WebParams = @{
    Uri       = $Url
    UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
    OutFile   = $ZipPath
}

if ($ProxyUri) {
    Write-Log "INFO" "Proxy topology discovered: $ProxyUri"
    if ($ProxyUri -notlike "http*") { $ProxyUri = "http://$ProxyUri" }
    $WebParams.Add("Proxy", $ProxyUri)
    $WebParams.Add("ProxyUseDefaultCredentials", $true)
} else {
    Write-Log "INFO" "No proxy topology detected. Proceeding with direct routing."
}

# ---------------------------------------------------------------------
# IDEMPOTENT ORCHESTRATION PIPELINE
# ---------------------------------------------------------------------

# Step A: Workspace Provisioning
if (-not (Test-Path "$env:USERPROFILE\Programs")) {
    Write-Log "INFO" "Target userspace program directory missing. Provisioning workspace..."
    New-Item -ItemType Directory -Force -Path "$env:USERPROFILE\Programs" | Out-Null
}

# Step B: Package Fetching and Extraction
if (-not (Test-Path $BinaryPath)) {
    Write-Log "INFO" "Target binary '$BinaryPath' not found. Fetching remote asset distribution..."
    
    try {
        # Execute Download with Spinner
        Invoke-WithSpinner -StatusMessage "Downloading GNU Emacs binary archive" -ScriptBlock {
            Invoke-WebRequest @WebParams
        }
        Write-Log "SUCCESS" "Remote asset distribution downloaded successfully."
    }
    catch {
        Write-Log "ERROR" "Asset distribution fetch failed. Verify proxy or network routing. Technical details: $_"
        exit 1
    }

    # Extracting Workspace File Tree
    Write-Log "INFO" "Extracting payload file tree to destination target: $TargetDir"
    if (Test-Path $TargetDir) { Remove-Item $TargetDir -Recurse -Force }
    
    try {
        # Execute Extraction with Spinner
        Invoke-WithSpinner -StatusMessage "Extracting archive file tree payload" -ScriptBlock {
            Expand-Archive -Path $ZipPath -DestinationPath $TargetDir -Force
        }
        Write-Log "SUCCESS" "Payload extraction and deployment sequence completed."
    }
    catch {
        Write-Log "ERROR" "Failed to extract payload. Archive might be corrupted. Technical details: $_"
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
        exit 1
    }
    finally {
        if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    }
} else {
    Write-Log "SUCCESS" "Idempotency check passed: GNU Emacs is already deployed at '$BinaryPath'."
}

# Step C: Environment Variable Context Synchronization
$CurrentHome = [Environment]::GetEnvironmentVariable("HOME", "User")
if ($CurrentHome -ne $env:USERPROFILE) {
    Write-Log "INFO" "Synchronizing 'HOME' environment variable context for scope 'User'..."
    [Environment]::SetEnvironmentVariable("HOME", "$env:USERPROFILE", "User")
    $env:HOME = $env:USERPROFILE
    Write-Log "SUCCESS" "Environment context updated successfully."
} else {
    Write-Log "SUCCESS" "Idempotency check passed: 'HOME' environment variable is already well-formed."
}

# ---------------------------------------------------------------------
# PIPELINE COMPLETE
# ---------------------------------------------------------------------
Write-Log "SUCCESS" "Deployment orchestration completed successfully. Target is ready for operation."
Write-Log "INFO" "To execute, run: & `"$BinaryPath`""