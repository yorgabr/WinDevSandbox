Import-Module "$PSScriptRoot\..\network\BusterMyConnection\BusterMyConnection.psd1" -Force

Describe 'Invoke-BusterConnectivity' {

    Context 'Proxy succeeds' {
        Mock Test-Path { $true }
        Mock Start-Process {}
        Mock Invoke-WebRequest { $true }

        It 'returns proxy success' {
            (Invoke-BusterConnectivity).Mode | Should -Be 'Proxy'
        }
    }

    Context 'Direct succeeds' {
        Mock Test-Path { $false }
        Mock Invoke-WebRequest { $true }

        It 'returns direct success' {
            (Invoke-BusterConnectivity).Mode | Should -Be 'Direct'
        }
    }

    Context 'No connectivity' {
        Mock Test-Path { $false }
        Mock Invoke-WebRequest { throw }

        It 'returns failure' {
            (Invoke-BusterConnectivity).Success | Should -BeFalse
        }
    }
}