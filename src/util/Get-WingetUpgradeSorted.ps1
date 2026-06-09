#Requires -Version 5.1
<#
.SYNOPSIS
    Lists available Winget package upgrades, sorted by package name.

.DESCRIPTION
    Wraps 'winget upgrade' and safely parses its JSON output.
    Defensively extracts the first complete JSON object, ignoring
    any banner text or trailing human-readable output produced by winget.

.PARAMETER Quiet
    Suppresses all non-essential output; emits objects only.

.PARAMETER Version
    Prints script version and exits.

.PARAMETER Help
    Prints help and exits.

.PARAMETER WingetArgs
    Additional arguments forwarded verbatim to 'winget upgrade'.
#>

[CmdletBinding(PositionalBinding = $false)]
param (
    [switch]$Quiet,
    [switch]$Version,
    [switch]$Help,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$WingetArgs
)

#-------------------------------
# Script metadata
#-------------------------------
$ScriptVersion = "1.1.0"

if ($Version) {
    Write-Output "Get-WingetUpgradeSorted version $ScriptVersion"
    return
}

if ($Help) {
    Get-Help -Detailed $MyInvocation.MyCommand.Path
    return
}

#-------------------------------
# Internal reusable function
#-------------------------------
function Get-WingetUpgradeJson {
    param (
        [string[]]$Arguments
    )

    $cmd = @(
        'update'
        '--output', 'json'
        '--disable-interactivity'
        '--accept-source-agreements'
    ) + $Arguments

    $raw = & winget @cmd 2>$null

    if (-not $raw) {
        return $null
    }

    $text = $raw -join "`n"

    # Extract first complete JSON object defensively
    if ($text -notmatch '(?s)\{.*\}') {
        return $null
    }

    $jsonText = $Matches[0]

    return $jsonText | ConvertFrom-Json
}

#-------------------------------
# Main logic
#-------------------------------
try {
    $json = Get-WingetUpgradeJson -Arguments $WingetArgs

    if (-not $json) {
        return
    }

    # Winget's JSON structure is:
    # { Sources: [ { Packages: [ ... ] } ] }

    $packages =
        $json.Sources |
        ForEach-Object { $_.Packages } |
        Where-Object { $_ }

    if (-not $packages) {
        return
    }

    $result =
        $packages |
        Sort-Object Name |
        Select-Object `
            Name,
            PackageIdentifier,
            InstalledVersion,
            AvailableVersion,
            Source

    if ($Quiet) {
        $result
    }
    else {
        $result | Format-Table -AutoSize
    }
}
catch {
    if (-not $Quiet) {
        Write-Error $_
    }
}
