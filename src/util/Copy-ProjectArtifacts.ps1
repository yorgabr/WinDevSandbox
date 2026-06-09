#Requires -Version 5.1
<#
.SYNOPSIS
    Aggregates text-based project artifacts into the system clipboard.

.DESCRIPTION
    Recursively scans a directory, filters binary files by inspecting null
    bytes, respects .gitignore patterns and hardcoded rules, and copies the
    content of all detected text files to the clipboard with header markers.

.PARAMETER RootPath
    The starting directory for the scan. Defaults to the current location.

.PARAMETER IncludeMask
    Array of glob/wildcard patterns to INCLUDE files or directories.
    Example: '*.ps1','*.md' — accepts only those types.
    If omitted, all text files are candidates.

.PARAMETER ExcludeMask
    Array of glob/wildcard patterns to EXCLUDE files or directories.
    Example: '*.min.js','vendor/*'
    Applied AFTER IncludeMask and BEFORE .gitignore rules.

.PARAMETER MaxFileSizeKB
    Maximum size in KB per file. Default: 512 KB.
    Larger files are skipped with a warning.

.PARAMETER MaxTotalSizeKB
    Maximum total output size in KB. Default: 3072 KB (3 MB).
    Processing stops when the limit is reached.

.PARAMETER NullByteCheckBytes
    Number of bytes read for binary detection. Default: 512.

.PARAMETER Encoding
    Encoding used to read file contents. Default: UTF8.

.EXAMPLE
    .\Copy-ProjectArtifacts.ps1
    Copies all text files in the current directory to the clipboard.

.EXAMPLE
    .\Copy-ProjectArtifacts.ps1 -IncludeMask '*.ps1','*.md'
    Copies only .ps1 and .md files.

.EXAMPLE
    .\Copy-ProjectArtifacts.ps1 -ExcludeMask 'tests/*','*.spec.js' -MaxFileSizeKB 256
    Excludes the tests folder and spec files, limits each file to 256 KB.

.EXAMPLE
    .\Copy-ProjectArtifacts.ps1 -RootPath 'C:\MyProject' -IncludeMask '*.py' -Verbose
    Copies Python files from a specific path with verbose logging.

.NOTES
    Author  : Yorga Babuscan (yorgabr@gmail.com)
    Version : 2.1
    Env     : PowerShell 5.1+
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [string]$RootPath = (Get-Location).Path,

    [Parameter()]
    [string[]]$IncludeMask = @(),

    [Parameter()]
    [string[]]$ExcludeMask = @(),

    [Parameter()]
    [ValidateRange(1, 102400)]
    [int]$MaxFileSizeKB = 512,

    [Parameter()]
    [ValidateRange(1, 102400)]
    [int]$MaxTotalSizeKB = 3072,

    [Parameter()]
    [ValidateRange(128, 8192)]
    [int]$NullByteCheckBytes = 512,

    [Parameter()]
    [ValidateSet('UTF8', 'UTF7', 'UTF32', 'ASCII', 'Unicode', 'Default')]
    [string]$Encoding = 'UTF8'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Private Functions ─────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Returns $true if the file contains no null bytes within the first
    N bytes, indicating it is likely a text file.
#>
function Test-IsTextFile {
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [System.IO.FileInfo]$FileInfo,

        [int]$CheckBytes = 512
    )

    # Empty files are treated as text by convention
    if ($FileInfo.Length -eq 0) { return $true }

    $stream = $null
    try {
        $stream    = [System.IO.File]::OpenRead($FileInfo.FullName)
        $toRead    = [Math]::Min($CheckBytes, $FileInfo.Length)
        $buffer    = New-Object byte[] $toRead
        $bytesRead = $stream.Read($buffer, 0, $toRead)

        for ($i = 0; $i -lt $bytesRead; $i++) {
            if ($buffer[$i] -eq 0) { return $false }
        }
        return $true
    }
    catch {
        Write-Warning "Could not inspect '$($FileInfo.Name)': $_"
        return $false
    }
    finally {
        # Guarantees the stream is closed even when an exception is thrown
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

<#
.SYNOPSIS
    Converts a simple glob pattern into a regular expression string.

.NOTES
    Supported tokens:
        *   — any character except forward slash
        **  — any character including forward slash
        ?   — exactly one character (not a slash)
        /   at the start  → pattern is anchored to the project root
        /   at the end    → directory-only marker (treated as prefix match)
#>
function ConvertTo-RegexFromGlob {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    # Normalize path separators
    $p = $Pattern.Trim().Replace('\', '/')

    # Skip blank lines and comments (extra safety when parsing .gitignore)
    if ([string]::IsNullOrWhiteSpace($p) -or $p.StartsWith('#')) { return $null }

    # Negation patterns (!) are not supported in this version
    if ($p.StartsWith('!')) {
        Write-Verbose "Negation pattern not supported, skipped: $Pattern"
        return $null
    }

    $anchored = $p.StartsWith('/')
    if ($anchored) { $p = $p.TrimStart('/') }

    # Trailing slash signals directory-only; treat as prefix match
    if ($p.EndsWith('/')) { $p = $p.TrimEnd('/') }

    # Escape all regex special characters before restoring glob tokens
    $p = [regex]::Escape($p)

    # Restore glob semantics:
    #   \*\* → .*       (globstar — any path segment)
    #   \*   → [^/]*    (single-level wildcard)
    #   \?   → [^/]     (single character)
    $p = $p -replace '\\\*\\\*', '§GLOBSTAR§'
    $p = $p -replace '\\\*',     '[^/]*'
    $p = $p -replace '\\\?',     '[^/]'
    $p = $p -replace '§GLOBSTAR§', '.*'

    if ($anchored) {
        return "^$p(/.*)?$"
    }
    else {
        return "(^|.+/)$p(/.*)?$"
    }
}

<#
.SYNOPSIS
    Builds the consolidated list of ignore regular expressions from
    hardcoded rules, .gitignore, and any extra exclude patterns.
#>
function Build-IgnoreRegexList {
    [OutputType([string[]])]
    param(
        [string]  $GitignorePath,
        [string[]]$ExtraExcludes
    )

    # Rules that are always ignored, regardless of .gitignore
    $hardcodedPatterns = @(
        '.git/**',
        '.gitignore',
        '.coverage',
        '**/*.lock',
        '**/*.pdf',
        '.pytest_cache/**',
        '.ruff_cache/**',
        '.venv/**',
        'node_modules/**',
        '__pycache__/**',
        'dist/**',
        'build/**',
        '.idea/**',
        '.vscode/**'
    )

    $allPatterns = $hardcodedPatterns + $ExtraExcludes

    if (Test-Path $GitignorePath) {
        $gitignoreLines = Get-Content $GitignorePath -Encoding UTF8 |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_) -and
                -not $_.TrimStart().StartsWith('#')
            }
        $allPatterns += $gitignoreLines
        Write-Verbose "Read $($gitignoreLines.Count) rule(s) from .gitignore"
    }

    $regexList = $allPatterns |
        ForEach-Object { ConvertTo-RegexFromGlob $_ } |
        Where-Object   { $null -ne $_ }

    return $regexList
}

<#
.SYNOPSIS
    Returns $true if the relative path matches any ignore regular expression.
#>
function Test-ShouldIgnore {
    [OutputType([bool])]
    param(
        [string]  $RelativePath,
        [string[]]$RegexList
    )

    foreach ($rx in $RegexList) {
        if ($RelativePath -match $rx) { return $true }
    }
    return $false
}

<#
.SYNOPSIS
    Returns $true if the file passes the IncludeMask and ExcludeMask filters.

.NOTES
    Evaluation order:
        1. ExcludeMask  — if matched, the file is rejected immediately.
        2. IncludeMask  — if provided and not matched, the file is rejected.
        3. Otherwise    — the file is accepted.
#>
function Test-MatchesMask {
    [OutputType([bool])]
    param(
        [System.IO.FileInfo]$FileInfo,
        [string]            $RelativePath,
        [string[]]          $IncludeMask,
        [string[]]          $ExcludeMask
    )

    # Step 1 — Explicit exclusion by wildcard mask
    foreach ($mask in $ExcludeMask) {
        $normalizedMask = $mask.Replace('\', '/')
        if ($RelativePath  -like $normalizedMask) { return $false }
        if ($FileInfo.Name -like $normalizedMask) { return $false }
    }

    # Step 2 — Explicit inclusion by wildcard mask
    if ($IncludeMask.Count -gt 0) {
        foreach ($mask in $IncludeMask) {
            if ($FileInfo.Name -like $mask) { return $true }
        }
        return $false
    }

    return $true
}

# ── Main Process ──────────────────────────────────────────────────────────────

process {
    # Validate RootPath explicitly instead of using ValidateScript in param(),
    # which fails when no argument is supplied because $_ is null at that point
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) {
        Write-Error "RootPath does not exist or is not a directory: '$RootPath'"
        exit 1
    }

    # Normalize RootPath — remove any trailing slash
    $RootPath      = $RootPath.TrimEnd('\', '/')
    $maxFileBytes  = $MaxFileSizeKB  * 1KB
    $maxTotalBytes = $MaxTotalSizeKB * 1KB

    Write-Verbose "RootPath       : $RootPath"
    Write-Verbose "IncludeMask    : $($IncludeMask    -join ', ')"
    Write-Verbose "ExcludeMask    : $($ExcludeMask    -join ', ')"
    Write-Verbose "MaxFileSizeKB  : $MaxFileSizeKB KB"
    Write-Verbose "MaxTotalSizeKB : $MaxTotalSizeKB KB"

    # Build the ignore regex list
    $gitignorePath = Join-Path $RootPath '.gitignore'
    $ignoreRegexes = Build-IgnoreRegexList `
                        -GitignorePath $gitignorePath `
                        -ExtraExcludes $ExcludeMask

    Write-Verbose "Compiled ignore rules: $($ignoreRegexes.Count)"

    # Runtime statistics
    $stats = [PSCustomObject]@{
        Processed  = 0
        Skipped    = 0
        TooLarge   = 0
        Binary     = 0
        Ignored    = 0
        TotalBytes = 0
    }

    $outputParts  = [System.Collections.Generic.List[string]]::new()
    $totalChars   = 0
    $limitReached = $false

    # Enumerate files — -LiteralPath avoids issues with brackets in names
    # Sort-Object ensures a deterministic output order across runs
    $allFiles = Get-ChildItem -LiteralPath $RootPath -Recurse -File |
                    Sort-Object FullName

    foreach ($file in $allFiles) {

        # Relative path with forward slashes for cross-platform consistency
        $relativePath = $file.FullName.Substring($RootPath.Length + 1).Replace('\', '/')

        # Filter 1: ignore rules (hardcoded + .gitignore + ExcludeMask)
        if (Test-ShouldIgnore -RelativePath $relativePath -RegexList $ignoreRegexes) {
            Write-Verbose "IGNORED   : $relativePath"
            $stats.Ignored++
            $stats.Skipped++
            continue
        }

        # Filter 2: IncludeMask / ExcludeMask (simple -like wildcards)
        if (-not (Test-MatchesMask -FileInfo      $file `
                                   -RelativePath  $relativePath `
                                   -IncludeMask   $IncludeMask `
                                   -ExcludeMask   $ExcludeMask)) {
            Write-Verbose "MASK      : $relativePath"
            $stats.Skipped++
            continue
        }

        # Filter 3: individual file size
        if ($file.Length -gt $maxFileBytes) {
            Write-Warning "File too large ($([Math]::Round($file.Length / 1KB, 1)) KB), skipped: $relativePath"
            $stats.TooLarge++
            $stats.Skipped++
            continue
        }

        # Filter 4: binary detection via null-byte inspection
        if (-not (Test-IsTextFile -FileInfo $file -CheckBytes $NullByteCheckBytes)) {
            Write-Verbose "BINARY    : $relativePath"
            $stats.Binary++
            $stats.Skipped++
            continue
        }

        # Read file content
        try {
            $content = [System.IO.File]::ReadAllText(
                $file.FullName,
                [System.Text.Encoding]::$Encoding
            )
        }
        catch {
            Write-Warning "Failed to read '$relativePath': $_"
            $stats.Skipped++
            continue
        }

        # Filter 5: cumulative output size limit
        $entryLength = $relativePath.Length + $content.Length + 20
        if (($totalChars + $entryLength) -gt $maxTotalBytes) {
            Write-Warning "Total limit of $MaxTotalSizeKB KB reached. Processing stopped."
            $limitReached = $true
            break
        }

        $outputParts.Add("=== $relativePath ===")
        $outputParts.Add($content.TrimEnd())
        $outputParts.Add('')

        $totalChars       += $entryLength
        $stats.Processed++
        $stats.TotalBytes += $file.Length
        Write-Verbose "INCLUDED  : $relativePath ($([Math]::Round($file.Length / 1KB, 1)) KB)"
    }

    # Write to clipboard
    if ($outputParts.Count -gt 0) {
        $finalOutput = [System.String]::Join([System.Environment]::NewLine, $outputParts)

        if ($PSCmdlet.ShouldProcess('Clipboard', 'Write aggregated content')) {
            Set-Clipboard -Value $finalOutput
        }

        Write-Host "`n  Done!" -ForegroundColor Green
        Write-Host ("  Files included     : {0}"    -f $stats.Processed)  -ForegroundColor Cyan
        Write-Host ("  Files skipped      : {0}"    -f $stats.Skipped)    -ForegroundColor Yellow
        Write-Host ("    Ignored by rule  : {0}"    -f $stats.Ignored)    -ForegroundColor DarkYellow
        Write-Host ("    Binary files     : {0}"    -f $stats.Binary)     -ForegroundColor DarkYellow
        Write-Host ("    Exceeds size     : {0}"    -f $stats.TooLarge)   -ForegroundColor DarkYellow
        Write-Host ("  Total size         : {0} KB" -f [Math]::Round($stats.TotalBytes / 1KB, 1)) -ForegroundColor Cyan

        if ($limitReached) {
            Write-Host "`n  Output truncated — increase -MaxTotalSizeKB if needed." -ForegroundColor Red
        }
    }
    else {
        Write-Host 'No text files found matching the given criteria.' -ForegroundColor Yellow
    }
}
