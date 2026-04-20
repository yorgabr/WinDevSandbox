#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 test suite for BusterMyConnection.psm1.

.DESCRIPTION
    Covers every branch of Invoke-BusterConnectivity and Test-DirectConnectivity
    using module-scoped mocks (-ModuleName BusterMyConnection) so that no real
    network, filesystem or process calls are ever made.

    Mock placement rule (Pester 5):
      Mock -ModuleName <M> <Cmd> — intercepts <Cmd> when called from within module <M>.
      Because BusterMyConnection imports Network.psm1 at load time, all Network
      functions (Test-LocalProxy, Set-ProxyEnvironment, etc.) are looked up via
      BusterMyConnection's session state; they must therefore be mocked with
      -ModuleName BusterMyConnection, not -ModuleName Network.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $RepoRoot = Resolve-Path "$PSScriptRoot\.."
    Import-Module "$RepoRoot\network\BusterMyConnection\BusterMyConnection.psd1" -Force
    Import-Module "$RepoRoot\network\lib\Network.psm1" -Force
}

# ===========================================================================
Describe 'Invoke-BusterConnectivity' {
# ===========================================================================

    # -----------------------------------------------------------------------
    Context 'CNTLM path exists and local proxy is reachable' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path           { $true }
            Mock -ModuleName BusterMyConnection Start-Process       {}
            Mock -ModuleName BusterMyConnection Start-Sleep         {}
            Mock -ModuleName BusterMyConnection Test-LocalProxy     { $true }
            Mock -ModuleName BusterMyConnection Set-ProxyEnvironment {}
        }

        It 'returns Mode=Proxy with Success=$true' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'Proxy'
            $r.Success | Should -BeTrue
        }

        It 'launches the CNTLM process' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Process -Exactly 1
        }

        It 'waits after launching CNTLM' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Sleep -Exactly 1
        }

        It 'activates the proxy environment' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Set-ProxyEnvironment -Exactly 1
        }

        It 'passes the ProxyPort to Test-LocalProxy' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -ProxyPort 8080 -Silent
            Should -Invoke -ModuleName BusterMyConnection Test-LocalProxy `
                -ParameterFilter { $Port -eq 8080 } -Exactly 1
        }

        It 'passes TimeoutSeconds to Test-LocalProxy' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -TimeoutSeconds 15 -Silent
            Should -Invoke -ModuleName BusterMyConnection Test-LocalProxy `
                -ParameterFilter { $TimeoutSeconds -eq 15 } -Exactly 1
        }

        It 'does not call Clear-ProxyEnvironment when proxy succeeds' {
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment {}
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 0
        }
    }

    # -----------------------------------------------------------------------
    Context 'CNTLM path exists but proxy is unreachable; direct internet succeeds' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path                { $true }
            Mock -ModuleName BusterMyConnection Start-Process            {}
            Mock -ModuleName BusterMyConnection Start-Sleep              {}
            Mock -ModuleName BusterMyConnection Test-LocalProxy          { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment   {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity  { $true }
        }

        It 'returns Mode=Direct with Success=$true' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'Direct'
            $r.Success | Should -BeTrue
        }

        It 'clears proxy environment before the direct fallback' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 1
        }

        It 'does not activate proxy environment' {
            Mock -ModuleName BusterMyConnection Set-ProxyEnvironment {}
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Set-ProxyEnvironment -Exactly 0
        }

        It 'passes TimeoutSeconds to Test-DirectConnectivity' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -TimeoutSeconds 20 -Silent
            Should -Invoke -ModuleName BusterMyConnection Test-DirectConnectivity `
                -ParameterFilter { $TimeoutSeconds -eq 20 } -Exactly 1
        }
    }

    # -----------------------------------------------------------------------
    Context 'CNTLM path exists, proxy unreachable, direct also fails' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path                { $true }
            Mock -ModuleName BusterMyConnection Start-Process            {}
            Mock -ModuleName BusterMyConnection Start-Sleep              {}
            Mock -ModuleName BusterMyConnection Test-LocalProxy          { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment   {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity  { $false }
        }

        It 'returns Mode=None with Success=$false' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'None'
            $r.Success | Should -BeFalse
        }

        It 'still clears proxy environment' {
            Invoke-BusterConnectivity -CntlmPath 'C:\fake\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 1
        }
    }

    # -----------------------------------------------------------------------
    Context 'CNTLM path is absent; direct internet succeeds' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path                { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment   {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity  { $true }
        }

        It 'returns Mode=Direct with Success=$true' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'Direct'
            $r.Success | Should -BeTrue
        }

        It 'never launches the CNTLM process' {
            Mock -ModuleName BusterMyConnection Start-Process {}
            Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Process -Exactly 0
        }

        It 'never sleeps (no CNTLM to wait for)' {
            Mock -ModuleName BusterMyConnection Start-Sleep {}
            Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Start-Sleep -Exactly 0
        }

        It 'clears proxy environment' {
            Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            Should -Invoke -ModuleName BusterMyConnection Clear-ProxyEnvironment -Exactly 1
        }
    }

    # -----------------------------------------------------------------------
    Context 'CNTLM path is absent and direct internet also fails' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path                { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment   {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity  { $false }
        }

        It 'returns Mode=None with Success=$false' {
            $r = Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' -Silent
            $r.Mode    | Should -Be 'None'
            $r.Success | Should -BeFalse
        }
    }

    # -----------------------------------------------------------------------
    Context 'Verbose output when -Silent is omitted' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-Path                { $false }
            Mock -ModuleName BusterMyConnection Clear-ProxyEnvironment   {}
            Mock -ModuleName BusterMyConnection Test-DirectConnectivity  { $false }
        }

        It 'does not throw when called without -Silent' {
            { Invoke-BusterConnectivity -CntlmPath 'C:\no\cntlm.exe' } | Should -Not -Throw
        }
    }
}


# ===========================================================================
Describe 'Test-DirectConnectivity' {
# ===========================================================================
# Test-DirectConnectivity is defined at module scope but not listed in
# FunctionsToExport in the .psd1 manifest, so we invoke it via InModuleScope.
# Mocks for Test-DirectInternet use -ModuleName BusterMyConnection because
# that is the module from which the call originates.

    # -----------------------------------------------------------------------
    Context 'Test-DirectInternet returns $true' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-DirectInternet { $true }
        }

        It 'returns $true' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity } | Should -BeTrue
        }

        It 'calls Test-DirectInternet exactly once' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity }
            Should -Invoke -ModuleName BusterMyConnection Test-DirectInternet -Exactly 1
        }
    }

    # -----------------------------------------------------------------------
    Context 'Test-DirectInternet returns $false' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-DirectInternet { $false }
        }

        It 'returns $false' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity } | Should -BeFalse
        }
    }

    # -----------------------------------------------------------------------
    Context 'TimeoutSeconds is forwarded to Test-DirectInternet' {
    # -----------------------------------------------------------------------
        BeforeAll {
            Mock -ModuleName BusterMyConnection Test-DirectInternet { $true }
        }

        It 'passes the specified TimeoutSeconds value' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity -TimeoutSeconds 12 }
            Should -Invoke -ModuleName BusterMyConnection Test-DirectInternet `
                -ParameterFilter { $TimeoutSeconds -eq 12 } -Exactly 1
        }

        It 'uses the default TimeoutSeconds of 5 when not specified' {
            InModuleScope BusterMyConnection { Test-DirectConnectivity }
            Should -Invoke -ModuleName BusterMyConnection Test-DirectInternet `
                -ParameterFilter { $TimeoutSeconds -eq 5 } -Exactly 1
        }
    }
}
