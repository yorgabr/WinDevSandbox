#requires -Version 5.1

Import-Module InvokeBuild -ErrorAction Stop

task Default Test

task Test {
    # Unblock all repository scripts before Pester tries to import any module.
    Get-ChildItem -Path $PSScriptRoot -Recurse -Include '*.ps1','*.psm1','*.psd1' -File |
        ForEach-Object { Unblock-File -LiteralPath $_.FullName -ErrorAction SilentlyContinue }

    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

    $pesterConfig = New-PesterConfiguration

    $pesterConfig.Run.Path     = 'tests'
    $pesterConfig.Run.PassThru = $true

    # CI mode
    $pesterConfig.Output.CIFormat = 'AzureDevOps'
    $pesterConfig.Run.Exit        = $true

    # Code coverage -- all production modules and scripts
    $pesterConfig.CodeCoverage.Enabled = $true
    $pesterConfig.CodeCoverage.Path    = @(
        'src/network/BusterMyConnection.psm1',
        'src/network/lib/Network.psm1',
        'src/network/Install-BusterProfile.ps1',
        'src/installers/Install-PesterLatest.ps1',
        'src/installers/Install-PSScriptAnalyzer.ps1',
        'src/Bootstrap-WinDevSandbox.ps1',
        'src/util/Copy-ProjectArtifacts.ps1',
        'src/util/Install-UserScripts.ps1'
    )

    Invoke-Pester -Configuration $pesterConfig
}
