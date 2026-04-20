#requires -Version 5.1

Import-Module InvokeBuild -ErrorAction Stop

task Default Test

task Test {
    # Unblock all repository scripts before Pester tries to import any module.
    # Files downloaded from the internet carry a Zone.Identifier alternate data
    # stream that triggers PowerShell 5.1's security prompt. Removing it here
    # ensures the warning never appears during a build run.
    Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1','*.psm1','*.psd1' -File |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

    $pesterConfig = New-PesterConfiguration

    $pesterConfig.Run.Path     = 'tests'
    $pesterConfig.Run.PassThru = $true

    # CI mode
    $pesterConfig.Output.CIFormat = 'AzureDevOps'
    $pesterConfig.Run.Exit        = $true

    # Code coverage -- all production modules measured together
    $pesterConfig.CodeCoverage.Enabled = $true
    $pesterConfig.CodeCoverage.Path    = @(
        'network/BusterMyConnection/BusterMyConnection.psm1',
        'network/lib/Network.psm1'
    )

    Invoke-Pester -Configuration $pesterConfig
}