# ============================================================
# Helper: Detect if we are running inside Windows Terminal
# ------------------------------------------------------------
# Windows Terminal always sets WT_SESSION.
# This allows optional ANSI usage without breaking conhost.exe
# ============================================================
$script:IsWindowsTerminal = [bool]$env:WT_SESSION


# ============================================================
# Compatibility layer enforcing UTF-8 as default
# ------------------------------------------------------------
# Force all applications and the terminal to use UTF-8
# ============================================================
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
chcp.com 65001


# ============================================================
# prompt: function for ensure advanced coloured prompt for 
# Windows PowerShell 5.1 compatible terminals
# ------------------------------------------------------------
# Features:
#   - Current Git branch
#   - Branch-based coloring
#   - Dirty working tree indicator (*)
#   - Ahead / behind remote indicators (? / ?)
#   - Admin vs user marker (# / >)
#   - Python virtualenv indicator
#   - Lightweight Git info cache
#
# Constraints:
#   - Windows PowerShell 5.1 compatible
#   - NO ANSI
#   - NO $PSStyle
# ============================================================
function prompt {

    # --------------------------------------------------------
    # Git cache (script scope, 2s TTL)
    # --------------------------------------------------------
    if (-not $script:GitPromptCache) {
        $script:GitPromptCache = @{
            Path = $null
            Time = Get-Date 0
            Data = $null
        }
    }

    # --------------------------------------------------------
    # Base prompt with PS major version & Path truncation (>30 chars)
    # --------------------------------------------------------
    Write-Host "PS$($PSVersionTable.PSVersion.Major) " -NoNewline -ForegroundColor Cyan
    
    $currentPath = (Get-Location).Path
    if ($currentPath.Length -gt 30) {
        $parts = $currentPath -split '\\'
        if ($parts.Count -ge 3) {
            $drive = $parts[0]
            $penultima = $parts[-2]
            $ultima = $parts[-1]
            $currentPath = "$drive\...\$penultima\$ultima"
        }
    }
    Write-Host $currentPath -NoNewline -ForegroundColor Green

    # --------------------------------------------------------
    # Python virtualenv
    # --------------------------------------------------------
    if ($env:VIRTUAL_ENV) {
        $venvName = Split-Path $env:VIRTUAL_ENV -Leaf
        Write-Host " ($venvName)" -NoNewline -ForegroundColor Magenta
    }

    # --------------------------------------------------------
    # Git info with cache
    # --------------------------------------------------------
    $gitInfo = $null
    $cwd = (Get-Location).Path
    $now = Get-Date

    if (
        $script:GitPromptCache.Path -eq $cwd -and
        ($now - $script:GitPromptCache.Time).TotalSeconds -lt 2
    ) {
        $gitInfo = $script:GitPromptCache.Data
    }
    else {
        if (Get-Command git -ErrorAction SilentlyContinue) {
            try {

                # Cheap and safe git inspection
                $status = git status -sb 2>$null
                if ($status -and $status[0] -match '^## ([^\.\s]+)') {

                    $branchRaw = $Matches[1]

                    # Normalize UTF-8 branch name for WinPS 5.1 console
                    $branch = [Text.Encoding]::UTF8.GetString(
                        [Text.Encoding]::UTF8.GetBytes($branchRaw)
                    )
                    
                    $dirty = ($status.Count -gt 1)

                    $ahead = 0
                    $behind = 0

                    if ($status[0] -match 'ahead (\d+)') {
                        $ahead = [int]$Matches[1]
                    }
                    if ($status[0] -match 'behind (\d+)') {
                        $behind = [int]$Matches[1]
                    }

                    $gitInfo = @{
                        Branch = $branch
                        Dirty  = $dirty
                        Ahead  = $ahead
                        Behind = $behind
                    }
                }
            }
            catch {
                # Don't care.
            }
        }

        $script:GitPromptCache = @{
            Path = $cwd
            Time = $now
            Data = $gitInfo
        }
    }

    # --------------------------------------------------------
    # Render Git info
    # --------------------------------------------------------
    if ($gitInfo) {

        switch -Regex ($gitInfo.Branch) {
            '^(main|master)$'           { $branchColor = 'Green' }
            '^(dev|develop)$'           { $branchColor = 'Cyan' }
            '^(feature|bugfix|hotfix)/' { $branchColor = 'Yellow' }
            default                     { $branchColor = 'Gray' }
        }

        Write-Host " [" -NoNewline -ForegroundColor DarkGray
        Write-Host $gitInfo.Branch -NoNewline -ForegroundColor $branchColor

        if ($gitInfo.Dirty) {
            Write-Host "*" -NoNewline -ForegroundColor Red
        }

        if ($gitInfo.Ahead -gt 0) {
            Write-Host " +$($gitInfo.Ahead)" -NoNewline -ForegroundColor Green
        }

        if ($gitInfo.Behind -gt 0) {
            Write-Host " -$($gitInfo.Behind)" -NoNewline -ForegroundColor Yellow
        }

        Write-Host "]" -NoNewline -ForegroundColor DarkGray
    }

    # --------------------------------------------------------
    # Admin or user terminator character
    # --------------------------------------------------------
    $isAdmin = (
        [Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if ($isAdmin) {
        Write-Host "#" -NoNewline -ForegroundColor Red
    }
    else {
        Write-Host ">" -NoNewline -ForegroundColor Cyan
    }

    return " "
}


# ============================================================
# Helper: Format file sizes into human readable units
# ------------------------------------------------------------
# Converts bytes into B / KB / MB / GB
# Used only for visual output (not pipeline)
# ============================================================
function Format-FileSize {
    param (
        [long]$Bytes
    )

    if ($Bytes -lt 1KB) {
        return "{0} B" -f $Bytes
    }
    elseif ($Bytes -lt 1MB) {
        return "{0:N1} KB" -f ($Bytes / 1KB)
    }
    elseif ($Bytes -lt 1GB) {
        return "{0:N1} MB" -f ($Bytes / 1MB)
    }
    else {
        return "{0:N2} GB" -f ($Bytes / 1GB)
    }
}


# ============================================================
# Helper: Write colored text (Windows PowerShell 5.1 safe)
# ------------------------------------------------------------
# Uses Write-Host exclusively.
# No ANSI, no VT sequences, no terminal detection.
# Guaranteed to work everywhere in WinPS 5.1.
# ============================================================
function Write-Colored {
    param (
        [string]$Text,
        [string]$Color,
        [switch]$NoNewline
    )

    Write-Host $Text -ForegroundColor $Color -NoNewline:$NoNewline
}


# ============================================================
# Remove default alias 'ls' to allow a custom implementation
# ------------------------------------------------------------
# PowerShell ships with 'ls' as an alias to Get-ChildItem.
# To implement a bash-like ls, the alias must be removed
# explicitly; otherwise it will always take precedence.
# ============================================================
if (Test-Path Alias:ls) {
    Remove-Item Alias:ls -Force
}


# ============================================================
# ls: Bash-like listing (names only, columns, colors, -F)
# ------------------------------------------------------------
# Supported flags:
#   -a  : include hidden files
#   -F  : append type indicators (/ * @)
#
# Behavior matches Bash ls closely:
#   - names only
#   - sorted by name
#   - column layout
#   - colors by type
# ============================================================
function ls {
    param (
        [switch]$a,
        [switch]$F
    )

    $items = Get-ChildItem -Force:$a | Sort-Object Name
    if (-not $items) { return }

    $width = $Host.UI.RawUI.WindowSize.Width

    $maxLen = ($items | ForEach-Object {
        $_.Name.Length + ($(if ($F) { 1 } else { 0 }))
    } | Measure-Object -Maximum).Maximum

    $colWidth = $maxLen + 2
    $cols = [Math]::Max(1, [Math]::Floor($width / $colWidth))
    $i = 0

    foreach ($item in $items) {

        $suffix = ""
        if ($F) {
            if ($item.PSIsContainer) { $suffix = "/" }
            elseif ($item.Attributes -match 'ReparsePoint') { $suffix = "@" }
            elseif ($item.Extension -match '\.(exe|bat|cmd|ps1)$') { $suffix = "*" }
        }

        if ($item.PSIsContainer) {
            $color = 'Cyan'
        }
        elseif ($item.Extension -match '\.(exe|bat|cmd|ps1)$') {
            $color = 'Green'
        }
        else {
            $color = 'Gray'
        }

        Write-Colored ($item.Name + $suffix).PadRight($colWidth) $color -NoNewline

        $i++
        if ($i -ge $cols) {
            Write-Host ""
            $i = 0
        }
    }

    if ($i -ne 0) {
        Write-Host ""
    }
}


# ============================================================
# ll: Detailed listing (Unix-like -l)
# ------------------------------------------------------------
# Shows:
#  - Mode
#  - LastWriteTime
#  - Size (human readable with -h)
#  - Name (colored)
# ============================================================
function ll {
    param (
        [switch]$a,
        [switch]$h
    )

    # --------------------------------------------------------
    # Normalize paths:
    # - No argument   -> current directory (.)
    # - One or more   -> treat as array, never as string
    # --------------------------------------------------------
    $paths = if ($args.Count -gt 0) {
        @($args)
    }
    else {
        @('.')
    }

    Get-ChildItem -Path $paths -Force:$a | ForEach-Object {

        # -------------------------------
        # Mode (same as Get-ChildItem)
        # -------------------------------
        $mode = $_.Mode.PadRight(7)

        # -------------------------------
        # Timestamp
        # -------------------------------
        $time = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm")

        # -------------------------------
        # Size or <DIR>
        # -------------------------------
        if ($_.PSIsContainer) {
            $size = "<DIR>".PadLeft(10)
        }
        else {
            if ($h) {
                $size = (Format-FileSize $_.Length).PadLeft(10)
            }
            else {
                $size = $_.Length.ToString().PadLeft(10)
            }
        }

        # -------------------------------
        # Color heuristics
        # -------------------------------
        if ($_.PSIsContainer) {
            $nameColor = 'Cyan'
        }
        elseif ($_.Attributes -match 'ReparsePoint') {
            $nameColor = 'Magenta'
        }
        elseif ($_.Extension -match '\.(exe|bat|cmd|ps1)$') {
            $nameColor = 'Green'
        }
        elseif ($_.Attributes -match 'Hidden') {
            $nameColor = 'DarkGray'
        }
        else {
            $nameColor = 'Gray'
        }

        # -------------------------------
        # Attribute emphasis
        # -------------------------------
        if ($_.Attributes -match 'ReadOnly') {
            $modeColor = 'Yellow'
        }
        else {
            $modeColor = 'DarkGray'
        }

        # -------------------------------
        # Output assembly
        # -------------------------------
        Write-Colored $mode $modeColor -NoNewline
        Write-Colored " $time " DarkGray -NoNewline
        Write-Colored $size DarkGray -NoNewline
        Write-Colored " " White -NoNewline
        Write-Colored $_.Name $nameColor
    }
}

Import-Module GitMe

# Completion for Buster-MyConnection.ps1
. 'C:\Users\mvale\AppData\Local\Programs\Scripts\completions\Buster-MyConnection.ps1.completion.ps1'


# Completion for Install-PSScriptAnalyzerManual.ps1
. 'C:\Users\mvale\AppData\Local\Programs\Scripts\completions\Install-PSScriptAnalyzerManual.ps1.completion.ps1'


# Completion for Install-UserScripts.ps1
. 'C:\Users\mvale\AppData\Local\Programs\Scripts\completions\Install-UserScripts.ps1.completion.ps1'


# Completion for Install-PSScriptAnalyzer.ps1
. 'C:\Users\mvale\AppData\Local\Programs\Scripts\completions\Install-PSScriptAnalyzer.ps1.completion.ps1'


# Completion for Copy-ProjectArtifacts.ps1
. 'C:\Users\mvale\AppData\Local\Programs\Scripts\completions\Copy-ProjectArtifacts.ps1.completion.ps1'


Import-Module GitMe -ErrorAction SilentlyContinue