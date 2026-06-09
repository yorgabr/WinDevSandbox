#Requires -Version 5.1
<#
.SYNOPSIS
    Installs scripts from a source directory into the user's script directory.

.DESCRIPTION
    Recursively scans a source directory for PowerShell (.ps1), Shell (.sh)
    and executable (shebang) scripts, copies them to the user's binary
    directory, optionally updates PATH, and generates argument completions
    for PowerShell scripts on Windows.

.PARAMETER SourcePath
    Source directory to scan. Defaults to the 'src' folder located at the
    project root (two levels above this script's location).

.PARAMETER DestPath
    Target installation directory. Defaults to the platform user bin path.

.PARAMETER NoPathUpdate
    When set, PATH is not modified.

.PARAMETER Force
    Overwrites existing files at the destination.

.PARAMETER Version
    Prints the script version and exits.

.PARAMETER Help
    Prints usage information and exits.

.EXAMPLE
    .\Install-UserScripts.ps1
    Installs all scripts found in <project-root>/src.

.EXAMPLE
    .\Install-UserScripts.ps1 -SourcePath 'C:\MyScripts' -Force
    Installs scripts from a custom path, overwriting existing files.

.NOTES
    Author  : Yorga Babuscan (yorgabr@gmail.com)
    Version : 2.0
    Env     : PowerShell 5.1+
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$SourcePath = '',

    [Parameter()]
    [string]$DestPath = '',

    [Parameter()]
    [switch]$NoPathUpdate,

    [Parameter()]
    [switch]$Force,

    [Parameter()]
    [switch]$Version,

    [Parameter()]
    [switch]$Help
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Constants ─────────────────────────────────────────────────────────────────

$SCRIPT_VERSION = '2.0.0'

# Project root is two levels above this script  (project/src/util/<script>)
$PROJECT_ROOT = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent

# Resolve SourcePath default here, after $PROJECT_ROOT is available
if ([string]::IsNullOrEmpty($SourcePath)) {
    $SourcePath = Join-Path -Path $PROJECT_ROOT -ChildPath 'src'
}

# ── ANSI colours (graceful fallback when the terminal does not support them) ──

$ESC    = [char]27
$Cyan   = "${ESC}[36m"
$Yellow = "${ESC}[33m"
$Green  = "${ESC}[32m"
$Red    = "${ESC}[31m"
$Reset  = "${ESC}[0m"

# ── Logging helpers ───────────────────────────────────────────────────────────

function Out-Info    { param([string]$Message) [Console]::Out.WriteLine("${Cyan}[INFO]${Reset} $Message")       }
function Out-Warn    { param([string]$Message) [Console]::Out.WriteLine("${Yellow}[WARN]${Reset} $Message")     }
function Out-Success { param([string]$Message) [Console]::Out.WriteLine("${Green}[SUCCESS]${Reset} $Message")   }
function Out-Err     { param([string]$Message) [Console]::Error.WriteLine("${Red}[ERROR]${Reset} $Message")     }

# ── Utility ───────────────────────────────────────────────────────────────────

function Get-ScriptName {
    return Split-Path -Leaf $PSCommandPath
}

function Show-Version {
    [Console]::Out.WriteLine("$(Get-ScriptName) version $SCRIPT_VERSION")
}

function Show-Usage {
    [Console]::Out.WriteLine(@"

$(Get-ScriptName) - Install scripts from a source directory to user space.

Usage:
    Install-UserScripts.ps1 [options]

Options:
    -SourcePath <path>   Source directory (default: <project-root>/src).
    -DestPath   <path>   Target directory (default: platform user bin).
    -NoPathUpdate        Do not modify PATH.
    -Force               Overwrite existing files.
    -Version             Show version and exit.
    -Help                Show this help and exit.

"@)
}

# ── Platform detection ────────────────────────────────────────────────────────

function Get-Platform {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # $IsWindows / $IsMacOS / $IsLinux are automatic variables in PS Core
        if ($IsWindows)     { return 'Windows' }
        elseif ($IsMacOS)   { return 'MacOS'   }
        elseif ($IsLinux)   { return 'Linux'   }
    }
    # PowerShell 5.1 (Desktop edition) only runs on Windows
    return 'Windows'
}

function Get-DefaultDestPath {
    param([string]$Platform)
    switch ($Platform) {
        'Windows' { return Join-Path -Path $env:LOCALAPPDATA -ChildPath 'Programs\Scripts' }
        default   { return Join-Path -Path $HOME             -ChildPath '.local/bin'        }
    }
}

# ── Shell profile resolution ──────────────────────────────────────────────────

function Get-ShellProfilePath {
    param([string]$Platform)
    switch ($Platform) {
        'Windows' {
            # CurrentUserAllHosts is preferred: applies to every PS host
            if ($PSVersionTable.PSEdition -eq 'Core') { return $PROFILE.CurrentUserAllHosts }
            return $PROFILE
        }
        'Linux' {
            $bashrc = Join-Path -Path $HOME -ChildPath '.bashrc'
            if (Test-Path -LiteralPath $bashrc) { return $bashrc }
            return (Join-Path -Path $HOME -ChildPath '.profile')
        }
        'MacOS' {
            $zshrc = Join-Path -Path $HOME -ChildPath '.zshrc'
            if (Test-Path -LiteralPath $zshrc) { return $zshrc }
            $bp = Join-Path -Path $HOME -ChildPath '.bash_profile'
            if (Test-Path -LiteralPath $bp) { return $bp }
            return (Join-Path -Path $HOME -ChildPath '.profile')
        }
        default { return (Join-Path -Path $HOME -ChildPath '.profile') }
    }
}

# ── PATH management ───────────────────────────────────────────────────────────

function Test-PathInEnvironment {
    param([string]$PathToCheck, [string]$Platform)
    $separator = if ($Platform -eq 'Windows') { ';' } else { ':' }
    $entries   = if ($Platform -eq 'Windows') {
        [Environment]::GetEnvironmentVariable('PATH', 'User')
    } else {
        $env:PATH
    }
    return ($entries -split [regex]::Escape($separator)) -contains $PathToCheck
}

function Add-PathToEnvironment {
    param([string]$NewPath, [string]$Platform, [string]$ProfilePath)

    if (Test-PathInEnvironment -PathToCheck $NewPath -Platform $Platform) {
        Out-Info 'PATH entry already present — no changes made.'
        return $true
    }

    Out-Info "Adding '$NewPath' to user PATH..."

    if ($Platform -eq 'Windows') {
        try {
            $current = [Environment]::GetEnvironmentVariable('PATH', 'User')
            [Environment]::SetEnvironmentVariable('PATH', "$current;$NewPath", 'User')
            $env:PATH = "$env:PATH;$NewPath"
            Out-Success 'Added to Windows user PATH.'
        }
        catch {
            Out-Warn "Could not modify Windows PATH: $($_.Exception.Message)"
            return $false
        }
    }
    else {
        $exportLine = "export PATH=`"`$PATH:$NewPath`""
        $parentDir  = Split-Path -Parent $ProfilePath

        if (-not (Test-Path -LiteralPath $parentDir)) {
            $null = New-Item -ItemType Directory -Path $parentDir -Force
        }

        Add-Content -Path $ProfilePath -Value "`n# Added by Install-UserScripts`n$exportLine`n"
        Out-Success "Added PATH export to '$ProfilePath'."
    }
    return $true
}

# ── Script discovery ──────────────────────────────────────────────────────────

function Get-ScriptFiles {
    param([string]$SourceDirectory)

    $scripts = [System.Collections.Generic.List[hashtable]]::new()

    # PowerShell scripts
    Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.ps1' -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $scripts.Add(@{
                Source   = $_.FullName
                Name     = $_.Name
                Type     = 'PowerShell'
                DestName = $_.Name
            })
        }

    # Shell scripts — strip .sh extension at destination
    Get-ChildItem -LiteralPath $SourceDirectory -Filter '*.sh' -File -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object {
            $scripts.Add(@{
                Source   = $_.FullName
                Name     = $_.Name
                Type     = 'Shell'
                DestName = ($_.Name -replace '\.sh$', '')
            })
        }

    # Extensionless executables identified by shebang line
    $knownExtensions = @('.ps1', '.sh', '.md', '.txt', '.json', '.xml', '.yaml', '.yml')
    Get-ChildItem -LiteralPath $SourceDirectory -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -notin $knownExtensions } |
        ForEach-Object {
            $firstLine = Get-Content -LiteralPath $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue
            if ($firstLine -match '^#!') {
                $scripts.Add(@{
                    Source   = $_.FullName
                    Name     = $_.Name
                    Type     = 'Executable'
                    DestName = $_.Name
                })
            }
        }

    return $scripts
}

# ── Script installation ───────────────────────────────────────────────────────

function Install-Script {
    param(
        [hashtable]$ScriptInfo,
        [string]   $DestinationDirectory,
        [switch]   $Force
    )

    $destFile = Join-Path -Path $DestinationDirectory -ChildPath $ScriptInfo.DestName

    if (Test-Path -LiteralPath $destFile) {
        if (-not $Force) {
            Out-Warn "Already exists: '$($ScriptInfo.DestName)'. Use -Force to overwrite."
            return $false
        }
        Out-Info "Overwriting: '$($ScriptInfo.DestName)'"
    }

    try {
        Copy-Item -LiteralPath $ScriptInfo.Source -Destination $destFile -Force:$Force

        # Make non-PS scripts executable on POSIX systems
        if ($ScriptInfo.Type -ne 'PowerShell' -and (Get-Platform) -ne 'Windows') {
            & chmod +x $destFile 2>$null
        }

        Out-Success "Installed: $($ScriptInfo.Name) -> $($ScriptInfo.DestName)"
        return $true
    }
    catch {
        Out-Err "Failed to install '$($ScriptInfo.Name)': $($_.Exception.Message)"
        return $false
    }
}

# ── Argument completion generation ───────────────────────────────────────────

function Get-PowerShellCompletion {
    param([string]$ScriptPath, [string]$ScriptName)

    $content      = Get-Content -LiteralPath $ScriptPath -Raw -ErrorAction SilentlyContinue
    $paramMatches = [regex]::Matches($content, '\[Parameter[^\]]*\][^\[]*\[([^\]]+)\]\$([A-Za-z0-9_]+)')

    if ($paramMatches.Count -eq 0) { return $null }

    $paramNames = $paramMatches | ForEach-Object { $_.Groups[2].Value }
    $paramList  = ($paramNames | ForEach-Object { "'$_'" }) -join ', '

    return @"
# Auto-generated completion for $ScriptName
Register-ArgumentCompleter -CommandName '$ScriptName' -ScriptBlock {
    param(`$commandName, `$parameterName, `$wordToComplete, `$commandAst, `$fakeBoundParameters)
    `$params = @($paramList)
    if (`$wordToComplete -like '-*') {
        `$params |
            Where-Object { `$_ -like "`$wordToComplete*" } |
            ForEach-Object {
                [System.Management.Automation.CompletionResult]::new(
                    "-`$_", `$_, 'ParameterName', `$_
                )
            }
    }
}
"@
}

function Install-Completions {
    param(
        [System.Collections.Generic.List[hashtable]]$InstalledScripts,
        [string]$DestinationDirectory
    )

    $completionDir = Join-Path -Path $DestinationDirectory -ChildPath 'completions'
    $null = New-Item -ItemType Directory -Path $completionDir -Force -ErrorAction SilentlyContinue

    $profilePath = $PROFILE.CurrentUserCurrentHost

    foreach ($script in $InstalledScripts) {
        if ($script.Type -ne 'PowerShell') { continue }

        $completion = Get-PowerShellCompletion -ScriptPath $script.Source -ScriptName $script.DestName
        if (-not $completion) { continue }

        $completionFile = Join-Path -Path $completionDir -ChildPath "$($script.DestName).completion.ps1"
        Set-Content -Path $completionFile -Value $completion -Encoding UTF8
        Out-Info "Generated completion: '$($script.DestName)'"

        # Dot-source the completion file from the user profile if not already present
        if (Test-Path -LiteralPath $profilePath) {
            $profileContent = Get-Content -LiteralPath $profilePath -Raw
            if ($profileContent -notlike "*$completionFile*") {
                Add-Content -Path $profilePath `
                    -Value "`n# Completion for $($script.DestName)`n. '$completionFile'`n"
            }
        }
    }
}

# ── Entry point ───────────────────────────────────────────────────────────────

function Invoke-Main {
    if ($Version) { Show-Version; exit 0 }
    if ($Help)    { Show-Usage;   exit 0 }

    $platform = Get-Platform
    Out-Info "Detected platform : $platform"
    Out-Info "Project root      : $PROJECT_ROOT"

    if ([string]::IsNullOrEmpty($DestPath)) {
        $script:DestPath = Get-DefaultDestPath -Platform $platform
    }

    Out-Info "Source            : $SourcePath"
    Out-Info "Destination       : $DestPath"

    # Validate source
    if (-not (Test-Path -LiteralPath $SourcePath -PathType Container)) {
        Out-Err "Source directory does not exist: $SourcePath"
        exit 1
    }

    # Ensure destination exists
    if (-not (Test-Path -LiteralPath $DestPath)) {
        Out-Info "Creating destination directory: $DestPath"
        $null = New-Item -ItemType Directory -Path $DestPath -Force
    }

    # Discover scripts
    $scripts = Get-ScriptFiles -SourceDirectory $SourcePath

    if ($scripts.Count -eq 0) {
        Out-Warn "No installable scripts found in '$SourcePath'."
        exit 0
    }

    Out-Info "Found $($scripts.Count) script(s) to install."

    # Install
    $installed = [System.Collections.Generic.List[hashtable]]::new()
    $failed    = 0

    foreach ($script in $scripts) {
        if ($PSCmdlet.ShouldProcess($script.Name, 'Install script')) {
            if (Install-Script -ScriptInfo $script -DestinationDirectory $DestPath -Force:$Force) {
                $installed.Add($script)
            }
            else {
                $failed++
            }
        }
    }

    # Update PATH
    if (-not $NoPathUpdate) {
        $profilePath = Get-ShellProfilePath -Platform $platform
        $pathUpdated = Add-PathToEnvironment -NewPath $DestPath -Platform $platform -ProfilePath $profilePath
        if ($pathUpdated -and $platform -ne 'Windows') {
            Out-Info "PATH updated in '$profilePath'."
        }
    }

    # Generate completions (Windows / PowerShell only)
    if ($installed.Count -gt 0 -and $platform -eq 'Windows') {
        Install-Completions -InstalledScripts $installed -DestinationDirectory $DestPath
    }

    # Summary
    Out-Success '=== Installation complete ==='
    Out-Info    "Installed : $($installed.Count) script(s)"
    if ($failed -gt 0) { Out-Warn "Failed    : $failed script(s)" }

    if (-not $NoPathUpdate) {
        Out-Info "Scripts available at: $DestPath"
        if ($platform -eq 'Windows') {
            Out-Info "Restart PowerShell or open a new terminal to apply PATH changes."
        }
    }
}

Invoke-Main
