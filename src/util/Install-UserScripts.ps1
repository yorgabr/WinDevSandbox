[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath "src"),

    [Parameter(Mandatory=$false)]
    [string]$DestPath = "",

    [Parameter(Mandatory=$false)]
    [switch]$NoPathUpdate,

    [Parameter(Mandatory=$false)]
    [switch]$Force,

    [Parameter(Mandatory=$false)]
    [switch]$Version,

    [Parameter(Mandatory=$false)]
    [switch]$Help
)

$script:IsWindowsPowerShell = $PSVersionTable.PSEdition -eq 'Desktop' -or $PSVersionTable.PSVersion.Major -le 5

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SCRIPT_VERSION = "1.0.0"

$ESC    = [char]27
$Cyan   = "${ESC}[36m"
$Yellow = "${ESC}[33m"
$Green  = "${ESC}[32m"
$Red    = "${ESC}[31m"
$Reset  = "${ESC}[0m"

function Out-Info    { param([string]$Message) [Console]::Out.WriteLine("$Cyan[INFO]$Reset $Message") }
function Out-Warn    { param([string]$Message) [Console]::Out.WriteLine("$Yellow[WARN]$Reset $Message") }
function Out-Success { param([string]$Message) [Console]::Out.WriteLine("$Green[SUCCESS]$Reset $Message") }
function Out-Error   { param([string]$Message) [Console]::Error.WriteLine("$Red[ERROR]$Reset $Message") }

function Get-ScriptName { return Split-Path -Leaf $PSCommandPath }

function Show-Version {
    $name = Get-ScriptName
    [Console]::Out.WriteLine("$name version $SCRIPT_VERSION")
}

function Show-Usage {
@"
Install-UserScripts.ps1 - Install scripts from source directory to user space.
Usage:
    Install-UserScripts.ps1 [options]
Options:
    -SourcePath PATH    Source directory (default: ./src).
    -DestPath PATH      Target directory (default: platform user bin).
    -NoPathUpdate       Do not modify PATH.
    -Force              Overwrite existing files.
    -Version            Show version.
    -Help               Show help.
"@
}

function Get-Platform {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        if ($IsWindows -or (-not (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue))) { return 'Windows' }
        elseif ($IsMacOS)  { return 'MacOS' }
        elseif ($IsLinux)  { return 'Linux' }
    }
    return 'Windows'
}

function Get-DefaultDestPath {
    param([string]$Platform)
    switch ($Platform) {
        'Windows' { return Join-Path -Path $env:LOCALAPPDATA -ChildPath "Programs\Scripts" }
        'Linux'   { return Join-Path -Path $HOME -ChildPath ".local/bin" }
        'MacOS'   { return Join-Path -Path $HOME -ChildPath ".local/bin" }
        default   { return Join-Path -Path $HOME -ChildPath ".local/bin" }
    }
}

function Get-ShellProfilePath {
    param([string]$Platform)
    switch ($Platform) {
        'Windows' {
            if ($PSVersionTable.PSEdition -eq 'Core') { return $PROFILE.CurrentUserAllHosts }
            else { return $PROFILE }
        }
        'Linux' {
            $bashrc = Join-Path -Path $HOME -ChildPath ".bashrc"
            if (Test-Path -LiteralPath $bashrc) { return $bashrc }
            return (Join-Path -Path $HOME -ChildPath ".profile")
        }
        'MacOS' {
            $zshrc = Join-Path -Path $HOME -ChildPath ".zshrc"
            if (Test-Path -LiteralPath $zshrc) { return $zshrc }
            $bp = Join-Path -Path $HOME -ChildPath ".bash_profile"
            if (Test-Path -LiteralPath $bp) { return $bp }
            return (Join-Path -Path $HOME -ChildPath ".profile")
        }
        default { return (Join-Path -Path $HOME -ChildPath ".profile") }
    }
}

function Test-PathInEnvironment {
    param([string]$PathToCheck, [string]$Platform)
    if ($Platform -eq 'Windows') {
        $entries = ([Environment]::GetEnvironmentVariable('PATH', 'User')) -split ';'
    } else {
        $entries = $env:PATH -split ':'
    }
    foreach ($e in $entries) { if ($e -eq $PathToCheck) { return $true } }
    return $false
}

function Add-PathToEnvironment {
    param([string]$NewPath, [string]$Platform, [string]$ProfilePath)
    Out-Info "Adding $NewPath to user PATH..."
    if ($Platform -eq 'Windows') {
        try {
            $cur = [Environment]::GetEnvironmentVariable('PATH', 'User')
            if ($cur -notlike "*$NewPath*") {
                [Environment]::SetEnvironmentVariable('PATH', "$cur;$NewPath", 'User')
                Out-Success "Added to Windows user PATH"
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
        $exportLine = "export PATH=`"`$PATH:$NewPath`""
        if (Test-Path -LiteralPath $ProfilePath) {
            $c = Get-Content -LiteralPath $ProfilePath -Raw
            if ($c -like "*$NewPath*") { Out-Info "Path already present in $ProfilePath"; return $true }
        }
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $ProfilePath) -Force -ErrorAction SilentlyContinue
        Add-Content -Path $ProfilePath -Value "`n# Added by Install-UserScripts`n$exportLine`n"
        Out-Success "Added PATH export to $ProfilePath"
    }
    return $true
}

function Get-ScriptFiles {
    param([string]$SourceDirectory)
    if (-not (Test-Path -LiteralPath $SourceDirectory)) {
        Out-Error "Source directory not found: $SourceDirectory"
        exit 1
    }
    $scripts = @()
    Get-ChildItem -Path $SourceDirectory -Filter "*.ps1" -File -ErrorAction SilentlyContinue |
        ForEach-Object { $scripts += @{ Source=$_.FullName; Name=$_.Name; Type='PowerShell'; DestName=$_.Name } }
    Get-ChildItem -Path $SourceDirectory -Filter "*.sh" -File -ErrorAction SilentlyContinue |
        ForEach-Object { $scripts += @{ Source=$_.FullName; Name=$_.Name; Type='Shell'; DestName=($_.Name -replace '\.sh$','') } }
    Get-ChildItem -Path $SourceDirectory -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -notin @('.ps1','.sh','.md','.txt','.json','.xml','.yaml','.yml') } |
        ForEach-Object {
            $fl = Get-Content -LiteralPath $_.FullName -TotalCount 1 -ErrorAction SilentlyContinue
            if ($fl -match '^#!') {
                $scripts += @{ Source=$_.FullName; Name=$_.Name; Type='Executable'; DestName=$_.Name }
            }
        }
    return $scripts
}

function Install-Script {
    param([hashtable]$ScriptInfo, [string]$DestinationDirectory, [switch]$Force)
    $destPath = Join-Path -Path $DestinationDirectory -ChildPath $ScriptInfo.DestName
    if (Test-Path -LiteralPath $destPath) {
        if (-not $Force) {
            Out-Warn "File already exists: $($ScriptInfo.DestName). Use -Force to overwrite."
            return $false
        }
        Out-Info "Overwriting existing file: $($ScriptInfo.DestName)"
    }
    try {
        Copy-Item -LiteralPath $ScriptInfo.Source -Destination $destPath -Force:$Force
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
    param([string]$ScriptPath, [string]$ScriptName)
    $content = Get-Content -LiteralPath $ScriptPath -Raw
    $paramMatches = [regex]::Matches($content, '\[Parameter[^\]]*\][^\[]*\[([^\]]+)\]\$([A-Za-z0-9_]+)')
    if ($paramMatches.Count -eq 0) { return $null }
    $paramNames = @()
    foreach ($m in $paramMatches) {
        $paramNames += $m.Groups[2].Value
    }
    return @"
# Auto-generated completion for $ScriptName
Register-ArgumentCompleter -CommandName '$ScriptName' -ScriptBlock {
    param(`$commandName, `$parameterName, `$wordToComplete, `$commandAst, `$fakeBoundParameters)
    `$params = @($(($paramNames | ForEach-Object { "'$_'" }) -join ', '))
    if (`$wordToComplete -like '-*') {
        return `$params | Where-Object { `$_ -like "`$wordToComplete*" } | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new(`"-`$_", `$_, 'ParameterName', `$_)
        }
    }
}
"@
}

function Install-Completions {
    param([array]$InstalledScripts, [string]$DestinationDirectory)
    $completionDir = Join-Path -Path $DestinationDirectory -ChildPath "completions"
    $null = New-Item -ItemType Directory -Path $completionDir -Force -ErrorAction SilentlyContinue
    $profilePath = $PROFILE.CurrentUserCurrentHost
    foreach ($script in $InstalledScripts) {
        if ($script.Type -ne 'PowerShell') { continue }
        $completion = Generate-PowerShellCompletion -ScriptPath $script.Source -ScriptName $script.DestName
        if ($completion) {
            $completionFile = Join-Path -Path $completionDir -ChildPath "$($script.DestName).completion.ps1"
            Set-Content -Path $completionFile -Value $completion
            Out-Info "Generated completion for $($script.DestName)"
            if (Test-Path -LiteralPath $profilePath) {
                $pc = Get-Content -LiteralPath $profilePath -Raw
                if ($pc -notlike "*$completionFile*") {
                    Add-Content -Path $profilePath -Value "`n# Completion for $($script.DestName)`n. '$completionFile'`n"
                }
            }
        }
    }
}

function Invoke-Main {
    if ($Version) { Show-Version; exit 0 }
    if ($Help)    { Show-Usage;   exit 0 }

    $platform = Get-Platform
    Out-Info "Detected platform: $platform"

    if ([string]::IsNullOrEmpty($DestPath)) {
        $DestPath = Get-DefaultDestPath -Platform $platform
    }

    Out-Info "Source: $SourcePath"
    Out-Info "Destination: $DestPath"

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        Out-Error "Source directory does not exist: $SourcePath"
        exit 1
    }

    if (-not (Test-Path -LiteralPath $DestPath)) {
        Out-Info "Creating destination directory: $DestPath"
        $null = New-Item -ItemType Directory -Path $DestPath -Force
    }

    $scripts = Get-ScriptFiles -SourceDirectory $SourcePath

    if ($scripts.Count -eq 0) {
        Out-Warn "No scripts found in $SourcePath"
        exit 0
    }

    Out-Info "Found $($scripts.Count) script(s) to install"

    $installed = @()
    $failed = 0

    foreach ($script in $scripts) {
        if (Install-Script -ScriptInfo $script -DestinationDirectory $DestPath -Force:$Force) {
            $installed += $script
        } else {
            $failed++
        }
    }

    if (-not $NoPathUpdate) {
        $profilePath = Get-ShellProfilePath -Platform $platform
        $pathUpdated = Add-PathToEnvironment -NewPath $DestPath -Platform $platform -ProfilePath $profilePath
        if ($pathUpdated -and $platform -ne 'Windows') {
            Out-Info "PATH updated in $profilePath"
        }
    }

    if ($installed.Count -gt 0 -and $platform -eq 'Windows') {
        Install-Completions -InstalledScripts $installed -DestinationDirectory $DestPath
    }

    Out-Success "=== Installation complete ==="
    Out-Info "Installed: $($installed.Count) script(s)"
    if ($failed -gt 0) { Out-Warn "Failed: $failed script(s)" }

    if (-not $NoPathUpdate) {
        Out-Info "Scripts are available in: $DestPath"
        if ($platform -eq 'Windows') {
            Out-Info "Restart PowerShell or run 'refreshenv' to update PATH"
        }
    }
}

Invoke-Main
