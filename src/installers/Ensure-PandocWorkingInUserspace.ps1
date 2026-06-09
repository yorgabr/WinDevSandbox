<#
.SYNOPSIS
    Ensures Pandoc and MiKTeX are installed and configured in userspace
    for PDF generation from Markdown files.

.DESCRIPTION
    This script applies a desired-state model (DSC-inspired, no admin required)
    to install and configure all dependencies needed to convert Markdown to PDF
    via Pandoc + pdflatex/xelatex, entirely within the current user's scope:

        - Pandoc        : universal document converter
        - MiKTeX        : LaTeX distribution for Windows (per-user install)
        - LaTeX packages: booktabs, longtable, hyperref, xcolor, microtype,
                          parskip, footnotehyper, bookmark, xurl, upquote,
                          lm (Latin Modern fonts), and transitive dependencies

    Each resource follows the DSC pattern:
        Get-*   : reads current state
        Test-*  : returns $true if already in desired state, $false otherwise
        Set-*   : enforces desired state (only called when Test-* returns $false)

    After a successful run, the following command should work without errors:

        pandoc document.md -o output.pdf --pdf-engine=xelatex

    Requirements:
        - Windows 10/11
        - PowerShell 5.1 or later
        - winget (bundled with Windows 11 by default)
        - Internet access

    Limitations:
        - Unicode emojis (e.g. checkmark U+2705) are not rendered by pdflatex.
          Use --pdf-engine=xelatex for Unicode support, or replace emojis with
          plain text before converting.
        - First-time MiKTeX installation may take several minutes.

.PARAMETER SkipPackages
    If specified, skips installation of individual LaTeX packages via mpm.
    Useful when MiKTeX is already installed with on-the-fly package install
    enabled.

.PARAMETER Force
    Re-applies all resources even if Test-* reports the desired state is
    already met. Equivalent to DSC -Force.

.EXAMPLE
    .\Ensure-PandocWorkingInUserspace.ps1
    Default run: applies only what is missing.

.EXAMPLE
    .\Ensure-PandocWorkingInUserspace.ps1 -SkipPackages
    Installs Pandoc and MiKTeX only, without installing individual LaTeX packages.

.EXAMPLE
    .\Ensure-PandocWorkingInUserspace.ps1 -Force
    Forces re-application of all resources regardless of current state.

.NOTES
    Author  : Yorga Babuscan
    Version : 2.0.0
    Date    : 2026-05-29
    PS      : 5.1+
    Pattern : DSC-inspired (Get / Test / Set) — no admin, no DSC engine required
#>

[CmdletBinding()]
param(
    [switch]$SkipPackages,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------

function Write-Step  { param([string]$M) Write-Host "`n==> $M" -ForegroundColor Cyan    }
function Write-Ok    { param([string]$M) Write-Host "    [OK]  $M" -ForegroundColor Green   }
function Write-Skip  { param([string]$M) Write-Host "    [--]  $M (already in desired state)" -ForegroundColor DarkGray }
function Write-Warn  { param([string]$M) Write-Host "    [!]   $M" -ForegroundColor Yellow  }
function Write-Apply { param([string]$M) Write-Host "    [SET] $M" -ForegroundColor Magenta }

# ---------------------------------------------------------------------------
# Shared utilities
# ---------------------------------------------------------------------------

function Test-CommandExists {
    <#
    .SYNOPSIS Returns $true if the given command is available on PATH. #>
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Assert-Winget {
    <#
    .SYNOPSIS Throws if winget is not available. #>
    if (-not (Test-CommandExists 'winget')) {
        throw ('winget not found. Install App Installer from the Microsoft Store ' +
               'or update Windows 11 to get it automatically.')
    }
}

function Invoke-Resource {
    <#
    .SYNOPSIS
        Applies a DSC-inspired resource by running Test-* and, if needed, Set-*.

    .PARAMETER Name
        Human-readable resource name used in log output.

    .PARAMETER TestScript
        ScriptBlock returning $true (desired state met) or $false (needs apply).

    .PARAMETER SetScript
        ScriptBlock that enforces the desired state.
    #>
    param(
        [string]$Name,
        [scriptblock]$TestScript,
        [scriptblock]$SetScript
    )

    Write-Step "Resource: $Name"

    $inDesiredState = & $TestScript

    if ($inDesiredState -and -not $Force) {
        Write-Skip $Name
        return
    }

    Write-Apply "Applying: $Name"
    & $SetScript
}

function Update-SessionPath {
    <#
    .SYNOPSIS
        Refreshes PATH for the current session from the registry,
        so newly installed tools are available without reopening the terminal.
    #>
    $machinePath = [System.Environment]::GetEnvironmentVariable('PATH', 'Machine')
    $userPath    = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
    $env:PATH    = (@($machinePath, $userPath) | Where-Object { $_ }) -join ';'
}

# ---------------------------------------------------------------------------
# Resource: Pandoc
# ---------------------------------------------------------------------------

function Get-PandocState {
    <#
    .SYNOPSIS Returns the installed Pandoc version string, or $null if absent. #>
    if (Test-CommandExists 'pandoc') {
        return (& pandoc --version 2>$null | Select-Object -First 1)
    }
    return $null
}

function Test-PandocResource {
    <#
    .SYNOPSIS Returns $true if Pandoc is already installed. #>
    $state = Get-PandocState
    if ($state) {
        Write-Ok "Pandoc found: $state"
        return $true
    }
    return $false
}

function Set-PandocResource {
    <#
    .SYNOPSIS Installs Pandoc via winget in user scope. #>
    Assert-Winget
    winget install --id JohnMacFarlane.Pandoc `
                   --scope user `
                   --silent `
                   --accept-package-agreements `
                   --accept-source-agreements

    Update-SessionPath

    if (Test-CommandExists 'pandoc') {
        Write-Ok 'Pandoc installed successfully.'
    } else {
        throw 'Pandoc was installed but is not on PATH. Please reopen the terminal and re-run.'
    }
}

# ---------------------------------------------------------------------------
# Resource: MiKTeX
# ---------------------------------------------------------------------------

function Get-MiKTeXState {
    <#
    .SYNOPSIS Returns the installed MiKTeX version string, or $null if absent. #>
    if (Test-CommandExists 'pdflatex') {
        return (& pdflatex --version 2>$null | Select-Object -First 1)
    }
    return $null
}

function Test-MiKTeXResource {
    <#
    .SYNOPSIS Returns $true if MiKTeX (pdflatex) is already installed. #>
    $state = Get-MiKTeXState
    if ($state) {
        Write-Ok "MiKTeX found: $state"
        return $true
    }
    return $false
}

function Set-MiKTeXResource {
    <#
    .SYNOPSIS Installs MiKTeX via winget in user scope. #>
    Assert-Winget
    Write-Host '    This may take several minutes on first install...'
    winget install --id MiKTeX.MiKTeX `
                   --scope user `
                   --silent `
                   --accept-package-agreements `
                   --accept-source-agreements

    Update-SessionPath

    if (Test-CommandExists 'pdflatex') {
        Write-Ok 'MiKTeX installed successfully.'
    } else {
        throw ('MiKTeX was installed but pdflatex is not on PATH. ' +
               'Please reopen the terminal and re-run.')
    }
}

# ---------------------------------------------------------------------------
# Resource: MiKTeX auto-install configuration
# ---------------------------------------------------------------------------

function Get-MiKTeXAutoInstallState {
    <#
    .SYNOPSIS
        Returns $true if MiKTeX is configured to install missing packages
        automatically (AutoInstall=1 in miktex.ini). #>
    if (-not (Test-CommandExists 'initexmf')) { return $false }

    $config = & initexmf --show-config-value '[MPM]AutoInstall' 2>$null
    return ($config -eq '1')
}

function Test-MiKTeXAutoInstallResource {
    <#
    .SYNOPSIS Returns $true if AutoInstall is already enabled. #>
    $state = Get-MiKTeXAutoInstallState
    if ($state) {
        Write-Ok 'MiKTeX on-the-fly package install: enabled.'
        return $true
    }
    return $false
}

function Set-MiKTeXAutoInstallResource {
    <#
    .SYNOPSIS Enables silent on-the-fly package installation in MiKTeX. #>
    if (-not (Test-CommandExists 'initexmf')) {
        Write-Warn 'initexmf not found; skipping auto-install configuration.'
        return
    }

    & initexmf --set-config-value '[MPM]AutoInstall=1' 2>$null
    & initexmf --update-fndb 2>$null
    & initexmf --mkmaps      2>$null

    Write-Ok 'MiKTeX configured: missing packages will be installed automatically.'
}

# ---------------------------------------------------------------------------
# Resource: LaTeX packages
# ---------------------------------------------------------------------------

# Full list of packages used by Pandoc's default LaTeX template,
# plus transitive dependencies identified during real-world PDF generation.
$script:RequiredLatexPackages = @(
    # Core Pandoc template dependencies
    'booktabs',        # Publication-quality tables (\toprule, \midrule, \bottomrule)
    'longtable',       # Tables that span multiple pages
    'hyperref',        # PDF hyperlinks and metadata
    'xcolor',          # Color support
    'microtype',       # Microtypography (kerning, protrusion)
    'parskip',         # Paragraph spacing without indentation
    'footnotehyper',   # Footnotes compatible with hyperref
    'bookmark',        # Enhanced PDF bookmarks
    'xurl',            # Line-breakable long URLs
    'upquote',         # Correct quotes in verbatim environments
    'lm',              # Latin Modern fonts (lmodern)
    # Math support
    'amsmath',         # AMS mathematical environments
    'amssymb',         # AMS mathematical symbols
    'amsfonts',        # AMS mathematical fonts
    # Tooling and utility packages
    'etoolbox',        # LaTeX programming toolkit
    'kvoptions',       # Key-value options for packages
    'kvsetkeys',       # Key-value key setting
    'ltxcmds',         # LaTeX utility commands
    'pdftexcmds',      # pdfTeX commands for LuaTeX/XeTeX compatibility
    'infwarerr',       # Warning and error handling
    'pdfescape',       # PDF string escaping
    'hycolor',         # Color support for hyperref
    'refcount',        # Reference counting
    'stringenc',       # String encoding utilities
    'intcalc',         # Integer arithmetic in LaTeX
    'bigintcalc',      # Large integer arithmetic
    'bitset',          # Bit-set operations
    'uniquecounter',   # Unique counters
    'rerunfilecheck',  # Detects if recompilation is needed
    'kvdefinekeys',    # Key-value key definition
    'gettitlestring',  # Document title string extraction
    'l3backend',       # L3 backend for pdfTeX
    'tools'            # LaTeX tools bundle (array, calc, longtable, etc.)
)

function Get-LaTeXPackageState {
    <#
    .SYNOPSIS
        Returns a hashtable mapping each required package name to $true (installed)
        or $false (missing). Relies on mpm --list for package enumeration. #>
    $installed = @{}
    $script:RequiredLatexPackages | ForEach-Object { $installed[$_] = $false }

    if (-not (Test-CommandExists 'mpm')) { return $installed }

    $installedList = & mpm --list 2>$null | ForEach-Object {
        ($_ -split '\s+')[0]   # first column is the package name
    }

    foreach ($pkg in $script:RequiredLatexPackages) {
        if ($installedList -contains $pkg) {
            $installed[$pkg] = $true
        }
    }
    return $installed
}

function Test-LaTeXPackagesResource {
    <#
    .SYNOPSIS
        Returns $true only if every required LaTeX package is already installed. #>
    $state   = Get-LaTeXPackageState
    $missing = $state.Keys | Where-Object { -not $state[$_] }

    if (-not $missing) {
        Write-Ok "All $($script:RequiredLatexPackages.Count) required LaTeX packages are present."
        return $true
    }

    Write-Host ("    Missing packages ({0}): {1}" -f @($missing).Count, ($missing -join ', ')) `
        -ForegroundColor DarkGray
    return $false
}

function Set-LaTeXPackagesResource {
    <#
    .SYNOPSIS Installs any missing LaTeX packages via mpm. #>
    if (-not (Test-CommandExists 'mpm')) {
        Write-Warn 'mpm not found; skipping LaTeX package installation.'
        return
    }

    $state   = Get-LaTeXPackageState
    $missing = @($state.Keys | Where-Object { -not $state[$_] })

    if ($Force) {
        # On -Force, reinstall everything regardless of state
        $missing = $script:RequiredLatexPackages
    }

    $total   = $missing.Count
    $current = 0

    foreach ($pkg in $missing) {
        $current++
        Write-Host ("    [{0:D2}/{1:D2}] {2}..." -f $current, $total, $pkg) -NoNewline
        try {
            # --install is deprecated in newer mpm but still functional
            & mpm --install=$pkg 2>&1 | Out-Null
            Write-Host ' ok' -ForegroundColor Green
        } catch {
            Write-Host ' warning (may already be installed)' -ForegroundColor Yellow
        }
    }

    Write-Ok 'LaTeX packages applied.'
}

# ---------------------------------------------------------------------------
# Resource: MiKTeX filename database
# ---------------------------------------------------------------------------

function Test-FndbResource {
    <#
    .SYNOPSIS
        Always returns $false — the FNDB refresh is cheap and always safe to run.
        Treated as a write-only convergence step. #>
    return $false
}

function Set-FndbResource {
    <#
    .SYNOPSIS Refreshes MiKTeX's filename database and font maps. #>
    if (-not (Test-CommandExists 'initexmf')) {
        Write-Warn 'initexmf not found; skipping FNDB refresh.'
        return
    }
    & initexmf --update-fndb 2>$null
    & initexmf --mkmaps      2>$null
    Write-Ok 'MiKTeX filename database and font maps refreshed.'
}

# ---------------------------------------------------------------------------
# Final verification
# ---------------------------------------------------------------------------

function Invoke-FinalCheck {
    <#
    .SYNOPSIS Verifies that all key binaries are reachable on PATH. #>
    Write-Step 'Final verification'

    $allOk = $true
    foreach ($cmd in @('pandoc', 'pdflatex', 'xelatex')) {
        if (Test-CommandExists $cmd) {
            $ver = & $cmd --version 2>$null | Select-Object -First 1
            Write-Ok "${cmd}: $ver"
        } else {
            Write-Warn "${cmd}: NOT found on PATH."
            $allOk = $false
        }
    }

    if ($allOk) {
        Write-Host "`n  All done! Example usage:" -ForegroundColor Green
        Write-Host '    pandoc document.md -o output.pdf --pdf-engine=xelatex' -ForegroundColor White
        Write-Host ''
        Write-Host '  Note: Unicode emojis are not supported by pdflatex.' -ForegroundColor DarkGray
        Write-Host '  Use xelatex or replace emojis with plain text before converting.' -ForegroundColor DarkGray
    } else {
        Write-Warn 'Some components were not found. Please reopen the terminal and re-run.'
        exit 1
    }
}

# ---------------------------------------------------------------------------
# Entry point — resource application order matters
# ---------------------------------------------------------------------------

try {
    Write-Host ''
    Write-Host '======================================================' -ForegroundColor Magenta
    Write-Host '  Ensure-PandocWorkingInUserspace.ps1  v2.0.0'         -ForegroundColor Magenta
    Write-Host '  DSC-inspired  |  userspace  |  no admin required'    -ForegroundColor Magenta
    Write-Host '======================================================'  -ForegroundColor Magenta

    Invoke-Resource -Name 'Pandoc' `
                    -TestScript { Test-PandocResource } `
                    -SetScript  { Set-PandocResource  }

    Invoke-Resource -Name 'MiKTeX' `
                    -TestScript { Test-MiKTeXResource } `
                    -SetScript  { Set-MiKTeXResource  }

    Invoke-Resource -Name 'MiKTeX AutoInstall configuration' `
                    -TestScript { Test-MiKTeXAutoInstallResource } `
                    -SetScript  { Set-MiKTeXAutoInstallResource  }

    if (-not $SkipPackages) {
        Invoke-Resource -Name 'Required LaTeX packages' `
                        -TestScript { Test-LaTeXPackagesResource } `
                        -SetScript  { Set-LaTeXPackagesResource  }
    }

    # FNDB refresh always runs after package changes (Test always returns $false)
    Invoke-Resource -Name 'MiKTeX FNDB refresh' `
                    -TestScript { Test-FndbResource } `
                    -SetScript  { Set-FndbResource  }

    Invoke-FinalCheck

} catch {
    Write-Host "`n[ERROR] $_" -ForegroundColor Red
    exit 1
}
