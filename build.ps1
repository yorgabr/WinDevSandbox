Import-Module InvokeBuild -ErrorAction Stop

task Default Test

task Test {
    Import-Module Pester -MinimumVersion 5.0.0
    Invoke-Pester -Path ./tests -CI -CodeCoverage ./network/BusterMyConnection/BusterMyConnection.psm1
}
