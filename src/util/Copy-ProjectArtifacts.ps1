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
    Features active tab-completion parsing workspace extensions.

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
    Utilizes dynamic auto-complete for extensions.

.EXAMPLE
    .\Copy-ProjectArtifacts.ps1 -ExcludeMask 'tests/*','*.spec.js' -MaxFileSizeKB 256
    Excludes specified directories and decreases size bounds.

.NOTES
    Author  : Yorga Babuscan (yorgabr@gmail.com)
    Version : 2.7.0
    Env     : PowerShell 5.1+ (Windows 11 Optimization)
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Position = 0)]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Container })]
    [string]$RootPath = $PWD.Path,

    [Parameter()]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        $target = if ($fakeBoundParameters.ContainsKey('RootPath')) { $fakeBoundParameters['RootPath'] } else { $PWD.Path }
        if (Test-Path -LiteralPath $target -PathType Container) {
            Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue |
                Group-Object Extension | Where-Object Name | ForEach-Object { "*$($_.Name)" } |
                Where-Object { $_ -like "$wordToComplete*" }
        }
    })]
    [string[]]$IncludeMask = @(),

    [Parameter()]
    [ArgumentCompleter({
        param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
        $target = if ($fakeBoundParameters.ContainsKey('RootPath')) { $fakeBoundParameters['RootPath'] } else { $PWD.Path }
        if (Test-Path -LiteralPath $target -PathType Container) {
            Get-ChildItem -LiteralPath $target -Recurse -File -ErrorAction SilentlyContinue |
                Group-Object Extension | Where-Object Name | ForEach-Object { "*$($_.Name)" } |
                Where-Object { $_ -like "$wordToComplete*" }
        }
    })]
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

function Test-IsTextFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        $FileInfo,

        [int]$CheckBytes = 512
    )

    if ($FileInfo.Length -eq 0) { return $true }

    $stream = $null
    try {
        $stream    = [System.IO.File]::OpenRead($FileInfo.FullName)
        $toRead    = [int][Math]::Min([long]$CheckBytes, [long]$FileInfo.Length)
        $buffer    = New-Object byte[] $toRead
        $bytesRead = $stream.Read($buffer, 0, $toRead)

        for ($i = 0; $i -lt $bytesRead; $i++) {
            if ($buffer[$i] -eq 0) { return $false }
        }
        return $true
    }
    catch {
        [Console]::Error.WriteLine("⚠️ Warning: Could not inspect '$($FileInfo.Name)': $_")
        return $false
    }
    finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function ConvertTo-RegexFromGlob {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Pattern
    )
    $p = $Pattern.Trim().Replace([char]92, [char]47)

    if ([string]::IsNullOrWhiteSpace($p) -or $p.StartsWith('#')) { return $null }

    if ($p.StartsWith('!')) {
        Write-Verbose "Negation pattern not supported, skipped: $Pattern"
        return $null
    }

    $anchored = $p.StartsWith('/')
    if ($anchored) { $p = $p.TrimStart([char]47) }
    if ($p.EndsWith('/')) { $p = $p.TrimEnd([char]47) }

    if ([string]::IsNullOrWhiteSpace($p)) { return $null }

    $p = [regex]::Escape($p)
    $p = $p -replace '\\\*\\\*', 'GLOBSTARTOKEN'
    $p = $p -replace '\\\*',     '[^/]*'
    $p = $p -replace '\\\?',     '[^/]'
    $p = $p -replace 'GLOBSTARTOKEN', '.*'

    if ($anchored) { return "^$p(/.*)?$" }
    else           { return "(^|.+/)$p(/.*)?$" }
}

function ConvertTo-IgnoreRegexList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [string]  $GitignorePath,
        [string[]]$ExtraExcludes = @()
    )

    $hardcodedPatterns = @(
        '.git/**', '.gitignore', '.coverage', '**/*.lock', '**/*.pdf',
        '.pytest_cache/**', '.ruff_cache/**', '.venv/**', 'node_modules/**',
        '__pycache__/**', 'dist/**', 'build/**', '.idea/**', '.vscode/**'
    )

    $allPatterns = @($hardcodedPatterns) + @($ExtraExcludes)

    if ($GitignorePath -and (Test-Path -LiteralPath $GitignorePath)) {
        $gitignoreLines = @(
            Get-Content -LiteralPath $GitignorePath -Encoding UTF8 |
                Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_) -and
                    -not $_.TrimStart().StartsWith('#')
                }
        )
        $allPatterns += $gitignoreLines
        Write-Verbose "Read $($gitignoreLines.Count) rule(s) from .gitignore"
    }

    $regexList = @(
        $allPatterns |
            ForEach-Object { ConvertTo-RegexFromGlob -Pattern $_ } |
            Where-Object   { $null -ne $_ }
    )

    return ,$regexList
}

function Test-ShouldIgnore {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]  $RelativePath,
        [string[]]$RegexList = @()
    )

    foreach ($rx in $RegexList) {
        if ($RelativePath -match $rx) { return $true }
    }
    return $false
}

function Test-MatchesMask {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        $FileInfo,
        [string]  $RelativePath,
        [string[]]$IncludeMask = @(),
        [string[]]$ExcludeMask = @()
    )

    foreach ($mask in $ExcludeMask) {
        $normalizedMask = $mask.Replace([char]92, [char]47)
        if ($RelativePath  -like $normalizedMask) { return $false }
        if ($FileInfo.Name -like $normalizedMask) { return $false }
    }

    if ($IncludeMask.Count -gt 0) {
        foreach ($mask in $IncludeMask) {
            if ($FileInfo.Name -like $mask) { return $true }
        }
        return $false
    }

    return $true
}

function Resolve-EncodingObject {
    [CmdletBinding()]
    [OutputType([System.Text.Encoding])]
    param(
        [Parameter(Mandatory)]
        [string]$Encoding
    )

    switch ($Encoding) {
        'UTF8'    { [System.Text.Encoding]::UTF8    }
        'UTF7'    { [System.Text.Encoding]::UTF7    }
        'UTF32'   { [System.Text.Encoding]::UTF32   }
        'ASCII'   { [System.Text.Encoding]::ASCII   }
        'Unicode' { [System.Text.Encoding]::Unicode }
        default   { [System.Text.Encoding]::Default }
    }
}

# ── Core Orchestrator ─────────────────────────────────────────────────────────

function Invoke-ProjectArtifactCopy {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([PSCustomObject])]
    param(
        [string]  $RootPath,
        [string[]]$IncludeMask        = @(),
        [string[]]$ExcludeMask        = @(),
        [int]     $MaxFileSizeKB      = 512,
        [int]     $MaxTotalSizeKB     = 3072,
        [int]     $NullByteCheckBytes = 512,
        [string]  $Encoding           = 'UTF8'
    )

    $RootPath = $RootPath.TrimEnd([char]92, [char]47)
    $maxFileBytes  = $MaxFileSizeKB  * 1KB
    $maxTotalBytes = $MaxTotalSizeKB * 1KB
    $encodingObj   = Resolve-EncodingObject -Encoding $Encoding

    $gitignorePath = Join-Path $RootPath '.gitignore'
    $ignoreRegexes = ConvertTo-IgnoreRegexList `
                        -GitignorePath $gitignorePath `
                        -ExtraExcludes $ExcludeMask

    $stats = [PSCustomObject]@{
        Processed    = 0
        Skipped      = 0
        TooLarge     = 0
        Binary       = 0
        Ignored      = 0
        TotalBytes   = 0
        LimitReached = $false
        Output       = ''
    }

    $outputParts = [System.Collections.Generic.List[string]]::new()
    $totalChars  = 0

    $allFiles = @(
        Get-ChildItem -LiteralPath $RootPath -Recurse -File |
            Sort-Object FullName
    )

    # Spinner Frame Configurations
    $spinnerFrames = @('⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏')
    $frameIndex    = 0
    $isInteractive = [Environment]::UserInteractive

    foreach ($file in $allFiles) {
        $relativePath = $file.FullName.Substring($RootPath.Length + 1).Replace([char]92, [char]47)

        # Draw UI Spinner safely via StdErr/Host interface to safeguard the stdout pipeline
        if ($isInteractive -and -not $PSBoundParameters.ContainsKey('Verbose')) {
            $frame = $spinnerFrames[$frameIndex++ % $spinnerFrames.Count]
            $statusText = "`r $frame Processing: $relativePath"
            if ($statusText.Length -gt 79) { $statusText = $statusText.Substring(0, 76) + "..." }
            [Console]::Write($statusText.PadRight(80).Substring(0, 80))
        }

        # Filter 1: ignore rules
        if (Test-ShouldIgnore -RelativePath $relativePath -RegexList $ignoreRegexes) {
            Write-Verbose "IGNORED   : $relativePath"
            $stats.Ignored++
            $stats.Skipped++
            continue
        }

        # Filter 2: include/exclude masks
        if (-not (Test-MatchesMask -FileInfo     $file `
                                   -RelativePath $relativePath `
                                   -IncludeMask  $IncludeMask `
                                   -ExcludeMask  $ExcludeMask)) {
            Write-Verbose "MASK      : $relativePath"
            $stats.Skipped++
            continue
        }

        # Filter 3: individual file size
        if ($file.Length -gt $maxFileBytes) {
            [Console]::Error.WriteLine("`r⚠️ Warning: File too large ($([Math]::Round($file.Length / 1KB, 1)) KB), skipped: $relativePath")
            $stats.TooLarge++
            $stats.Skipped++
            continue
        }

        # Filter 4: binary detection
        if (-not (Test-IsTextFile -FileInfo $file -CheckBytes $NullByteCheckBytes)) {
            Write-Verbose "BINARY    : $relativePath"
            $stats.Binary++
            $stats.Skipped++
            continue
        }

        # Read content
        try {
            $content = [System.IO.File]::ReadAllText($file.FullName, $encodingObj)
        }
        catch {
            [Console]::Error.WriteLine("`r⚠️ Warning: Failed to read '$relativePath': $_")
            $stats.Skipped++
            continue
        }

        # Filter 5: cumulative size limit
        $entryLength = $relativePath.Length + $content.Length + 20
        if (($totalChars + $entryLength) -gt $maxTotalBytes) {
            [Console]::Error.WriteLine("`r⚠️ Warning: Total limit of $MaxTotalSizeKB KB reached. Processing stopped.")
            $stats.LimitReached = $true
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

    # Wipe the last spinner trail cleanly
    if ($isInteractive) { [Console]::Write("`r".PadRight(80) + "`r") }

    if ($outputParts.Count -gt 0) {
        $finalOutput  = [System.String]::Join([System.Environment]::NewLine, $outputParts)
        $stats.Output = $finalOutput

        if ($PSCmdlet.ShouldProcess('Clipboard', 'Write aggregated content')) {
            Set-Clipboard -Value $finalOutput
        }
    }

    return $stats
}

# ── Entry Point ───────────────────────────────────────────────────────────────

if ($MyInvocation.InvocationName -ne '.') {

    $invokeParams = @{
        RootPath           = $RootPath
        IncludeMask        = $IncludeMask
        ExcludeMask        = $ExcludeMask
        MaxFileSizeKB      = $MaxFileSizeKB
        MaxTotalSizeKB     = $MaxTotalSizeKB
        NullByteCheckBytes = $NullByteCheckBytes
        Encoding           = $Encoding
    }
    if ($PSBoundParameters.ContainsKey('WhatIf'))  { $invokeParams['WhatIf']  = $PSBoundParameters['WhatIf'] }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $invokeParams['Confirm'] = $PSBoundParameters['Confirm'] }

    $stats = Invoke-ProjectArtifactCopy @invokeParams

    if ($stats.Processed -gt 0 -or $stats.Skipped -gt 0) {
        Write-Host "`n  Done!" -ForegroundColor Green
        Write-Host ("  Files included     : {0}"    -f $stats.Processed)  -ForegroundColor Cyan
        Write-Host ("  Files skipped      : {0}"    -f $stats.Skipped)    -ForegroundColor Yellow
        Write-Host ("    Ignored by rule  : {0}"    -f $stats.Ignored)    -ForegroundColor DarkYellow
        Write-Host ("    Binary files     : {0}"    -f $stats.Binary)     -ForegroundColor DarkYellow
        Write-Host ("    Exceeds size     : {0}"    -f $stats.TooLarge)   -ForegroundColor DarkYellow
        Write-Host ("  Total size         : {0} KB" -f [Math]::Round($stats.TotalBytes / 1KB, 1)) -ForegroundColor Cyan

        if ($stats.LimitReached) {
            [Console]::Error.WriteLine("`n❌ Error: Output truncated — increase -MaxTotalSizeKB if needed.")
        }
    }
    else {
        Write-Host 'No text files found matching the given criteria.' -ForegroundColor Yellow
    }
}