Set-StrictMode -Version Latest

Import-Module "$PSScriptRoot\..\network\BusterMyConnection\BusterMyConnection.psd1" -Force
Import-Module "$PSScriptRoot\..\network\lib\Network.psm1" -Force

Describe 'Invoke-BusterConnectivity' {

    Context 'Prefers proxy when available' {

        InModuleScope BusterMyConnection {

            Mock Test-Path { $true } -ModuleName BusterMyConnection

            Mock Test-LocalProxy {
                param([int]$Port, [int]$TimeoutSeconds)
                $true
            } -ModuleName Network

            Mock Test-DirectConnectivity {
                param([int]$TimeoutSeconds)
                $false
            } -ModuleName BusterMyConnection

            Mock Start-Process {}
            Mock Start-Sleep {}
            Mock Set-ProxyEnvironment {} -ModuleName Network
            Mock Clear-ProxyEnvironment {} -ModuleName Network

            It 'succeeds when proxy is preferred' {
                $result = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe'
                $result.Success | Should -BeTrue
                $result.Mode    | Should -Be 'Proxy'
            }
        }
    }

    Context 'Returns direct mode when proxy is unavailable' {

        InModuleScope BusterMyConnection {

            Mock Test-Path { $false } -ModuleName BusterMyConnection

            Mock Test-DirectConnectivity {
                param([int]$TimeoutSeconds)
                $true
            } -ModuleName BusterMyConnection

            Mock Clear-ProxyEnvironment {} -ModuleName Network

            It 'returns direct mode when proxy is unavailable' {
                $result = Invoke-BusterConnectivity -CntlmPath 'C:\none'
                $result.Success | Should -BeTrue
                $result.Mode    | Should -Be 'Direct'
            }
        }
    }

    Context 'CNTLM exists but proxy fails, falling back to direct' {

        InModuleScope BusterMyConnection {

            Mock Test-Path { $true } -ModuleName BusterMyConnection

            Mock Test-LocalProxy {
                param([int]$Port, [int]$TimeoutSeconds)
                $false
            } -ModuleName Network

            Mock Test-DirectConnectivity {
                param([int]$TimeoutSeconds)
                $true
            } -ModuleName BusterMyConnection

            Mock Start-Process {}
            Mock Start-Sleep {}
            Mock Clear-ProxyEnvironment {} -ModuleName Network

            It 'falls back to direct when proxy test fails' {
                $result = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe'
                $result.Success | Should -BeTrue
                $result.Mode    | Should -Be 'Direct'
            }
        }
    }

    Context 'No connectivity available at all' {

        InModuleScope BusterMyConnection {

            Mock Test-Path { $false } -ModuleName BusterMyConnection

            Mock Test-LocalProxy {
                param([int]$Port, [int]$TimeoutSeconds)
                $false
            } -ModuleName Network

            Mock Test-DirectConnectivity {
                param([int]$TimeoutSeconds)
                $false
            } -ModuleName BusterMyConnection

            Mock Clear-ProxyEnvironment {} -ModuleName Network

            It 'returns failure when no connectivity is available' {
                $result = Invoke-BusterConnectivity -CntlmPath 'C:\none'
                $result.Success | Should -BeFalse
                $result.Mode    | Should -Be 'None'
            }
        }
    }

    Context 'Verbose output path' {

        InModuleScope BusterMyConnection {

            Mock Test-Path { $false } -ModuleName BusterMyConnection

            Mock Test-DirectConnectivity {
                param([int]$TimeoutSeconds)
                $true
            } -ModuleName BusterMyConnection

            Mock Clear-ProxyEnvironment {} -ModuleName Network

            It 'emits verbose output when not silent' {
                Invoke-BusterConnectivity -CntlmPath 'C:\none' -Verbose | Out-Null
            }
        }
    }
}