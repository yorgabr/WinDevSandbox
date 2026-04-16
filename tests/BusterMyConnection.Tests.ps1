Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot\..\network\BusterMyConnection\BusterMyConnection.psd1" -Force
Import-Module "$PSScriptRoot\..\network\lib\Network.psm1" -Force

Describe 'Invoke-BusterConnectivity' {

    Context 'Prefers proxy when available' {

        InModuleScope BusterMyConnection {

            It 'succeeds when proxy is preferred' {
                $result = Invoke-BusterConnectivity `
                    -Silent `
                    -CntlmPath 'C:\fake\cntlm.exe'

                $result.Success | Should -BeTrue
                $result.Mode    | Should -BeIn @('Proxy','Direct')
            }
        }
    }

    Context 'Falls back to direct access' {

        InModuleScope BusterMyConnection {

            Mock Test-LocalProxy { $false } -ModuleName Network
            Mock Test-DirectInternet { $true } -ModuleName Network
            Mock Clear-ProxyEnvironment {} -ModuleName Network

            It 'returns direct mode when proxy is unavailable' {
                $result = Invoke-BusterConnectivity `
                    -Silent `
                    -CntlmPath 'C:\nonexistent\cntlm.exe'

                $result.Success | Should -BeTrue
                $result.Mode    | Should -Be 'Direct'
            }
        }
    }
}
