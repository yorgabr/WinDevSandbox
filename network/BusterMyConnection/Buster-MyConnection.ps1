[CmdletBinding()]
param([switch]$Silent)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'BusterMyConnection.psd1') -Force
$result = Invoke-BusterConnectivity -Silent:$Silent

if ($result.Success) {
    if (-not $Silent) { Write-Host "[SUCCESS] $($result.Mode) connectivity active." }
    exit 0
}

Write-Error "No usable connectivity."
exit 1