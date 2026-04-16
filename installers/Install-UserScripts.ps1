<#
.SYNOPSIS
    Install-UserScripts installs PowerShell and shell scripts from a source directory to 
    the user's local bin directory.

.DESCRIPTION
    This script provides a cross-platform, user-space installation mechanism for personal 
    automation tools. Rather than requiring administrative privileges or modifying system 
    directories, it establishes a dedicated user bin directory and populates it with 
    scripts from the specified source location.

    The installer is idempotent, allowing repeated execution to update or repair 
    installations without side effects. It handles platform differences gracefully, using 
    appropriate paths for Windows (%LOCALAPPDATA%\Programs\Scripts) versus Linux/macOS 
    (~/.local/bin). The implementation ensures that the destination directory is added to 
    the user's PATH persistently, making installed scripts immediately available in new 
    shell sessions.

    For PowerShell scripts, the installer additionally generates and installs argument 
    completers if the scripts follow the standard parameter naming conventions. This 
    enhances discoverability and usability of the installed tools.

    The script operates with minimal privileges, respecting the principle of least 
    privilege and maintaining system integrity while providing a seamless user experience.

.PARAMETER SourcePath
    The directory containing scripts to install. Defaults to './src' relative to the 
    installer location.

.PARAMETER DestPath
    The target directory for installation. Defaults to platform-appropriate user space 
    location.

.PARAMETER NoPathUpdate
    When specified, the installer will not attempt to modify the user's PATH environment 
    variable.

.PARAMETER Force
    Overwrite existing files without prompting.

.EXAMPLE
    Install-UserScripts
    
    Installs scripts from ./src to the default user bin directory, updating PATH as needed.

.EXAMPLE
    Install-UserScripts -SourcePath "./tools" -Force
    
    Installs from an alternative source directory, overwriting any existing files.

.NOTES
    File Name      : Install-UserScripts.ps1
    Author         : Yorga Babuscan (yorgabr@gmail.com)
    Prerequisite   : PowerShell 5.1 or higher
    Version        : 1.0.0
    License        : GPL-3.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory=$false, HelpMessage="Source directory containing scripts")]
    [string]$SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath "src"),

    [Parameter(Mandatory=$false, HelpMessage="Destination directory for installation")]
    [string]$DestPath = "",

    [Parameter(Mandatory=$false, HelpMessage="Skip PATH environment update")]
    [switch]$NoPathUpdate,

    [Parameter(Mandatory=$false, HelpMessage="Overwrite existing files without prompting")]
    [switch]$Force,

    [Parameter(Mandatory=$false, HelpMessage="Show script version")]
    [switch]$Version,

    [Parameter(Mandatory=$false, HelpMessage="Show detailed help")]
    [switch]$Help
)

# Version detection and strict mode
$script:IsWindowsPowerShell = $PSVersionTable.PSEdition -eq 'Desktop' -or $PSVersionTable.PSVersion.Major -le 5

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_VERSION = "1.0.0"

#__________ Color helpers for rich console output _________________________________________________
$ESC = [char]27
$Cyan   = "${ESC}[36m"
$Yellow = "${ESC}[33m"
$Green  = "${ESC}[32m"
$Red    = "${ESC}[31m"
$Reset  = "${ESC}[0m"

function Out-Info { 
    param([string]$Message) 
    [Console]::Out.WriteLine("$Cyan[INFO]$Reset $Message") 
}

function Out-Warn { 
    param([string]$Message) 
    [Console]::Out.WriteLine("$Yellow[WARN]$Reset $Message") 
}

function Out-Success { 
    param([string]$Message) 
    [Console]::Out.WriteLine("$Green[SUCCESS]$Reset $Message") 
}

function Out-Error { 
    param([string]$Message) 
    [Console]::Error.WriteLine("$Red[ERROR]$Reset $Message") 
}

#__________ Utility functions _____________________________________________________________________
function Get-ScriptName {
    return Split-Path -Leaf $PSCommandPath
}

function Show-Version {
    $name = Get-ScriptName
    [Console]::Out.WriteLine("$name version $SCRIPT_VERSION")
}

function Show-Usage {
    @"
Install-UserScripts.ps1 — Install scripts from source directory to user space.

Usage:
    Install-UserScripts.ps1 [options]

Options:
    -SourcePath PATH          Source directory containing scripts (default: ./src).
    -DestPath PATH            Target directory (default: platform-specific user bin).
    -NoPathUpdate             Do not modify PATH environment variable.
    -Force                    Overwrite existing files without prompting.
    -Version                  Show script version and exit.
    -Help                     Show this help and exit.

Examples:
    # Install from default source to default destination
    Install-UserScripts.ps1

    # Install from custom source, overwriting existing files
    Install-UserScripts.ps1 -SourcePath "./my-scripts" -Force

    # Install without modifying PATH
    Install-UserScripts.ps1 -NoPathUpdate

Author: Yorga Babuscan (yorgabr@gmail.com)
"@
}

#__________ Platform detection ____________________________________________________________________
function Get-Platform {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        if ($IsWindows -or (-not (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue))) {
            return 'Windows'
        } elseif ($IsMacOS) {
            return 'MacOS'
        } elseif ($IsLinux) {
            return 'Linux'
        }
    }
    return 'Windows'
}

function Get-DefaultDestPath {
    param([string]$Platform)
    
    switch ($Platform) {
        'Windows' {
            return Join-Path -Path $env:LOCALAPPDATA -ChildPath "Programs\Scripts"
        }
        'Linux' {
            return Join-Path -Path $HOME -ChildPath ".local/bin"
        }
        'MacOS' {
            return Join-Path -Path $HOME -ChildPath ".local/bin"
        }
        default {
            return Join-Path -Path $HOME -ChildPath ".local/bin"
        }
    }
}

function Get-ShellProfilePath {
    param([string]$Platform)
    
    switch ($Platform) {
        'Windows' {
            # PowerShell profile is the appropriate place for PATH on Windows
            if ($PSVersionTable.PSEdition -eq 'Core') {
                return $PROFILE.CurrentUserAllHosts
            } else {
                return $PROFILE
            }
        }
        'Linux' {
            # Prefer .bashrc, fallback to .profile
            $bashrc = Join-Path -Path $HOME -ChildPath ".bashrc"
            $profile = Join-Path -Path $HOME -ChildPath ".profile"
            if (Test-Path -LiteralPath $bashrc) {
                return $bashrc
            }
            return $profile
        }
        'MacOS' {
            # macOS uses .zshrc by default on newer systems, fallback to .bash_profile
            $zshrc = Join-Path -Path $HOME -ChildPath ".zshrc"
            $bashProfile = Join-Path -Path $HOME -ChildPath ".bash_profile"
            if (Test-Path -LiteralPath $zshrc) {
                return $zshrc
            }
            if (Test-Path -LiteralPath $bashProfile) {
                return $bashProfile
            }
            return (Join-Path -Path $HOME -ChildPath ".profile")
        }
        default {
            return (Join-Path -Path $HOME -ChildPath ".profile")
        }
    }
}

#__________ PATH management _______________________________________________________________________
function Test-PathInEnvironment {
    param(
        [string]$PathToCheck,
        [string]$Platform
    )
    
    if ($Platform -eq 'Windows') {
        $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
        $pathEntries = $currentPath -split ';'
    } else {
        # For Unix, we check both current process and common config files
        $currentPath = $env:PATH
        $pathEntries = $currentPath -split ':'
    }
    
    foreach ($entry in $pathEntries) {
        if ($entry -eq $PathToCheck) {
            return $true
        }
    }
    return $false
}

function Add-PathToEnvironment {
    param(
        [string]$NewPath,
        [string]$Platform,
        [string]$ProfilePath
    )
    
    Out-Info "Adding $NewPath to user PATH..."
    
    if ($Platform -eq 'Windows') {
        # Windows: Use .NET Environment API for persistent user PATH
        try {
            $currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
            
            if ($currentPath -notlike "*$NewPath*") {
                $newPathValue = "$currentPath;$NewPath"
                [Environment]::SetEnvironmentVariable('PATH', $newPathValue, 'User')
                Out-Success "Added to Windows user PATH"
                
                # Also update current session
                $env:PATH = "$env:PATH;$NewPath"
            } else {
                Out-Info "Path already present in environment"
            }
        }
        catch {
            Out-Warn "Could not modify Windows PATH: $($_.Exception.Message)"
            return $false
        }
    } else {
        # Linux/macOS: Add to shell profile
        $exportLine = "export PATH=`"`$PATH:$NewPath`""
        
        # Check if already in profile
        if (Test-Path -LiteralPath $ProfilePath) {
            $profileContent = Get-Content -LiteralPath $ProfilePath -Raw
            if ($profileContent -like "*$NewPath*") {
                Out-Info "Path already present in $ProfilePath"
                return $true
            }
        }
        
        # Add to profile
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $ProfilePath) -Force -ErrorAction SilentlyContinue
        Add-Content -Path $ProfilePath -Value "`n# Added by Install-UserScripts`n$exportLine`n"
        Out-Success "Added PATH export to $ProfilePath"
    }
    
    return $true
}

#__________ Script installation ___________________________________________________________________
function Get-ScriptFiles {
    param([string]$SourceDirectory)
    
    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        Out-Error "Source directory not found: $SourceDirectory"
        exit 1
    }
    
    # Find PowerShell scripts and shell scripts
    $scripts = @()
    
    # PowerShell scripts
    $psScripts = Get-ChildItem -Path $SourceDirectory -Filter "*.ps1" -File -ErrorAction SilentlyContinue
    foreach ($script in $psScripts) {
        $scripts += @{
            Source = $script.FullName
            Name = $script.Name
            Type = 'PowerShell'
            DestName = $script.Name
        }
    }
    
    # Shell scripts (but skip .ps1 to avoid double-counting if someone uses .ps1.sh)
    $shScripts = Get-ChildItem -Path $SourceDirectory -Filter "*.sh" -File -ErrorAction SilentlyContinue
    foreach ($script in $shScripts) {
        $scripts += @{
            Source = $script.FullName
            Name = $script.Name
            Type = 'Shell'
            # Remove .sh extension for destination (convention on Unix)
            DestName = $script.Name -replace '\.sh$',''
        }
    }
    
    # Also look for extensionless executables with shebang
    $allFiles = Get-ChildItem -Path $SourceDirectory -File -ErrorAction SilentlyContinue
    foreach ($file in $allFiles) {
        # Skip if already processed or has known extension
        if ($file.Extension -in @('.ps1', '.sh', '.md', '.txt', '.json', '.xml', '.yaml', '.yml')) {
            continue
        }
        
        # Check for shebang
        $firstLine = Get-Content -LiteralPath $file.FullName -TotalCount 1 -ErrorAction SilentlyContinue
        if ($firstLine -match '^#!') {
            $scripts += @{
                Source = $file.FullName
                Name = $file.Name
                Type = 'Executable'
                DestName = $file.Name
            }
        }
    }
    
    return $scripts
}

function Install-Script {
    param(
        [hashtable]$ScriptInfo,
        [string]$DestinationDirectory,
        [switch]$Force
    )
    
    $destPath = Join-Path -Path $DestinationDirectory -ChildPath $ScriptInfo.DestName
    
    # Check for existing file
    if (Test-Path -LiteralPath $destPath) {
        if (-not $Force) {
            Out-Warn "File already exists: $($ScriptInfo.DestName). Use -Force to overwrite."
            return $false
        }
        Out-Info "Overwriting existing file: $($ScriptInfo.DestName)"
    }
    
    # Copy the script
    try {
        Copy-Item -LiteralPath $ScriptInfo.Source -Destination $destPath -Force:$Force
        
        # Set executable permissions on Unix for shell scripts
        if ($ScriptInfo.Type -ne 'PowerShell' -and (Get-Platform) -ne 'Windows') {
            chmod +x "$destPath" 2>$null | Out-Null
        }
        
        Out-Success "Installed: $($ScriptInfo.Name) -> $($ScriptInfo.DestName)"
        return $true
    }
    catch {
        Out-Error "Failed to install $($ScriptInfo.Name): $($_.Exception.Message)"
        return $false
    }
}

function Generate-PowerShellCompletion {
    param(
        [string]$ScriptPath,
        [string]$ScriptName
    )
    
    # Parse script to find parameters (basic heuristic)
    $content = Get-Content -LiteralPath $ScriptPath -Raw
    
    # Look for param block parameters
    $paramMatches = [regex]::Matches($content, '\[Parameter[^\]]*\][^\[]*\[([^\]]+)\]\$([A-Za-z0-9_]+)')
    
    if ($paramMatches.Count -eq 0) {
        return $null
    }
    
    $paramNames = @()
    foreach ($match in $paramMatches) {
        $paramType = $match.Groups[1].Value
        $paramName = $match.Groups[2].Value
        $paramNames += $paramName
    }
    
    # Generate completion script
    $completionBlock = @"
# Auto-generated completion for $ScriptName
Register-ArgumentCompleter -CommandName '$ScriptName' -ScriptBlock {
    param(`$commandName, `$parameterName, `$wordToComplete, `$commandAst, `$fakeBoundParameters)
    
    `$params = @($(($paramNames | ForEach-Object { "'$_'" }) -join ', '))
    
    if (`$wordToComplete -like '-*') {
        return `$params | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`"-`$_", `$_ , 'ParameterName', `$_)
        }
    }
}
"@

    return $completionBlock
}

function Install-Completions {
    param(
        [array]$InstalledScripts,
        [string]$DestinationDirectory
    )
    
    $completionDir = Join-Path -Path $DestinationDirectory -ChildPath "completions"
    $null = New-Item -ItemType Directory -Path $completionDir -Force -ErrorAction SilentlyContinue
    
    $profilePath = $PROFILE.CurrentUserCurrentHost
    
    foreach ($script in $InstalledScripts) {
        if ($script.Type -ne 'PowerShell') {
            continue
        }
        
        $completion = Generate-PowerShellCompletion -ScriptPath $script.Source -ScriptName $script.DestName
        if ($completion) {
            $completionFile = Join-Path -Path $completionDir -ChildPath "$($script.DestName).completion.ps1"
            Set-Content -Path $completionFile -Value $completion
            Out-Info "Generated completion for $($script.DestName)"
            
            # Add to profile if not already present
            if (Test-Path -LiteralPath $profilePath) {
                $profileContent = Get-Content -LiteralPath $profilePath -Raw
                if ($profileContent -notlike "*$completionFile*") {
                    Add-Content -Path $profilePath -Value "`n# Completion for $($script.DestName)`n. '$completionFile'`n"
                }
            }
        }
    }
}

#__________ Main execution flow ___________________________________________________________________
function Invoke-Main {
    # Handle version and help
    if ($Version) {
        Show-Version
        exit 0
    }
    
    if ($Help) {
        Show-Usage
        exit 0
    }
    
    # Determine platform
    $platform = Get-Platform
    Out-Info "Detected platform: $platform"
    
    # Resolve destination path
    if ([string]::IsNullOrEmpty($DestPath)) {
        $DestPath = Get-DefaultDestPath -Platform $platform
    }
    
    Out-Info "Source: $SourcePath"
    Out-Info "Destination: $DestPath"
    
    # Validate source
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Out-Error "Source directory does not exist: $SourcePath"
        exit 1
    }
    
    # Create destination if needed
    if (-not (Test-Path -LiteralPath $DestPath)) {
        Out-Info "Creating destination directory: $DestPath"
        $null = New-Item -ItemType Directory -Path $DestPath -Force
    }
    
    # Get scripts to install
    $scripts = Get-ScriptFiles -SourceDirectory $SourcePath
    
    if ($scripts.Count -eq 0) {
        Out-Warn "No scripts found in $SourcePath"
        exit 0
    }
    
    Out-Info "Found $($scripts.Count) script(s) to install"
    
    # Install each script
    $installed = @()
    $failed = 0
    
    foreach ($script in $scripts) {
        if (Install-Script -ScriptInfo $script -DestinationDirectory $DestPath -Force:$Force) {
            $installed += $script
        } else {
            $failed++
        }
    }
    
    # Update PATH if requested
    if (-not $NoPathUpdate) {
        $profilePath = Get-ShellProfilePath -Platform $platform
        $pathUpdated = Add-PathToEnvironment -NewPath $DestPath -Platform $platform -ProfilePath $profilePath
        
        if ($pathUpdated -and $platform -ne 'Windows') {
            Out-Info "PATH updated in $profilePath"
            Out-Info "Run 'source $profilePath' or start a new shell to use installed scripts"
        }
    }
    
    # Generate completions for PowerShell scripts
    if ($installed.Count -gt 0 -and $platform -eq 'Windows') {
        Install-Completions -InstalledScripts $installed -DestinationDirectory $DestPath
    }
    
    # Summary
    Out-Success "=== Installation complete ==="
    Out-Info "Installed: $($installed.Count) script(s)"
    if ($failed -gt 0) {
        Out-Warn "Failed: $failed script(s)"
    }
    
    if (-not $NoPathUpdate) {
        Out-Info "Scripts are available in: $DestPath"
        if ($platform -eq 'Windows') {
            Out-Info "Restart PowerShell or run 'refreshenv' (if using Chocolatey) to update PATH"
        }
    }
}

# Begin execution
Invoke-Main