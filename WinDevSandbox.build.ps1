#requires -Version 5.1

Import-Module InvokeBuild -ErrorAction Stop

task Default Test

task Test {
    Import-Module Pester -MinimumVersion 5.0.0 -ErrorAction Stop

    $pesterConfig = New-PesterConfiguration

    $pesterConfig.Run.Path    = 'tests'
    $pesterConfig.Run.PassThru = $true

    # CI mode
    $pesterConfig.Output.CIFormat = 'AzureDevOps'
    $pesterConfig.Run.Exit        = $true

    # Code coverage — all production modules measured together
    $pesterConfig.CodeCoverage.Enabled = $true
    $pesterConfig.CodeCoverage.Path    = @(
        'network/BusterMyConnection/BusterMyConnection.psm1',
        'network/lib/Network.psm1'
    )

    Invoke-Pester -Configuration $pesterConfig
}
