#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for src/network/Install-BusterProfile.ps1.

.DESCRIPTION
    All file I/O is mocked so the real PowerShell profile is never touched.
    Each It block dot-sources the script with its own Action value so that
    the top-level switch statement is re-executed per test.
#>
Set-StrictMode -Version Latest

BeforeAll {
    # Install-BusterProfile.ps1 lives directly under src/network/
    $script:ScriptPath = Resolve-Path "$PSScriptRoot\..\src\network\Install-BusterProfile.ps1"
}

# ---------------------------------------------------------------------------
Describe "Install-BusterProfile - action 'install'" {
# ---------------------------------------------------------------------------

    Context 'Profile does not exist; marker is absent' {

        It 'creates the profile file' {
            Mock Test-Path     { $false }
            Mock New-Item      {}
            Mock Select-String { $false }
            Mock Add-Content   {}
            Mock Write-Host    {}

            . $script:ScriptPath -Action install

            Should -Invoke New-Item -Exactly 1
        }

        It 'appends the marker block to the profile' {
            Mock Test-Path     { $false }
            Mock New-Item      {}
            Mock Select-String { $false }
            Mock Add-Content   {}
            Mock Write-Host    {}

            . $script:ScriptPath -Action install

            Should -Invoke Add-Content -Exactly 1
        }

        It 'outputs an installation confirmation message' {
            Mock Test-Path     { $false }
            Mock New-Item      {}
            Mock Select-String { $false }
            Mock Add-Content   {}
            Mock Write-Host    {}

            . $script:ScriptPath -Action install

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*installed*' } -Exactly 1
        }
    }

    Context 'Profile exists; marker is already present' {

        It 'does not append content again (idempotent)' {
            Mock Test-Path     { $true }
            Mock New-Item      {}
            Mock Select-String { $true }
            Mock Add-Content   {}
            Mock Write-Host    {}

            . $script:ScriptPath -Action install

            Should -Invoke Add-Content -Exactly 0
        }

        It 'reports already installed' {
            Mock Test-Path     { $true }
            Mock New-Item      {}
            Mock Select-String { $true }
            Mock Add-Content   {}
            Mock Write-Host    {}

            . $script:ScriptPath -Action install

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*already*' } -Exactly 1
        }

        It 'does not create the profile file (it already exists)' {
            Mock Test-Path     { $true }
            Mock New-Item      {}
            Mock Select-String { $true }
            Mock Add-Content   {}
            Mock Write-Host    {}

            . $script:ScriptPath -Action install

            Should -Invoke New-Item -Exactly 0
        }
    }
}

# ---------------------------------------------------------------------------
Describe "Install-BusterProfile - action 'uninstall'" {
# ---------------------------------------------------------------------------

    Context 'Profile file does not exist' {

        It 'does not throw' {
            Mock Test-Path   { $false }
            Mock Set-Content {}
            Mock Write-Host  {}

            { . $script:ScriptPath -Action uninstall } | Should -Not -Throw
        }

        It 'does not attempt to write the profile' {
            Mock Test-Path   { $false }
            Mock Set-Content {}
            Mock Write-Host  {}

            . $script:ScriptPath -Action uninstall

            Should -Invoke Set-Content -Exactly 0
        }
    }

    Context 'Profile exists with marker lines' {

        BeforeEach {
            $script:FakeProfile = @(
                '# unrelated-A',
                '# WinDevSandbox network bootstrap',
                "Import-Module 'C:\...\BusterMyConnection.psd1'; Invoke-BusterConnectivity -Silent | Out-Null",
                '# unrelated-B'
            )
        }

        It 'writes filtered content back to the profile' {
            Mock Test-Path   { $true }
            Mock Get-Content { $script:FakeProfile }
            Mock Set-Content {}
            Mock Write-Host  {}

            . $script:ScriptPath -Action uninstall

            Should -Invoke Set-Content -Exactly 1
        }

        It 'strips the WinDevSandbox marker line' {
            Mock Test-Path   { $true }
            Mock Get-Content { $script:FakeProfile }
            Mock Set-Content {}
            Mock Write-Host  {}

            . $script:ScriptPath -Action uninstall

            Should -Invoke Set-Content -ParameterFilter {
                ($Value -join '') -notmatch 'WinDevSandbox network bootstrap'
            } -Exactly 1
        }

        It 'strips the Invoke-BusterConnectivity line' {
            Mock Test-Path   { $true }
            Mock Get-Content { $script:FakeProfile }
            Mock Set-Content {}
            Mock Write-Host  {}

            . $script:ScriptPath -Action uninstall

            Should -Invoke Set-Content -ParameterFilter {
                ($Value -join '') -notmatch 'Invoke-BusterConnectivity'
            } -Exactly 1
        }

        It 'preserves all unrelated lines' {
            Mock Test-Path   { $true }
            Mock Get-Content { $script:FakeProfile }
            Mock Set-Content {}
            Mock Write-Host  {}

            . $script:ScriptPath -Action uninstall

            Should -Invoke Set-Content -ParameterFilter {
                ($Value -join ' ') -match 'unrelated-A' -and
                ($Value -join ' ') -match 'unrelated-B'
            } -Exactly 1
        }

        It 'outputs a removal confirmation' {
            Mock Test-Path   { $true }
            Mock Get-Content { $script:FakeProfile }
            Mock Set-Content {}
            Mock Write-Host  {}

            . $script:ScriptPath -Action uninstall

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*removed*' } -Exactly 1
        }
    }
}

# ---------------------------------------------------------------------------
Describe "Install-BusterProfile - action 'status'" {
# ---------------------------------------------------------------------------

    Context 'Profile exists and marker is present' {

        It 'reports ACTIVE' {
            Mock Test-Path     { $true }
            Mock Select-String { $true }
            Mock Write-Host    {}

            . $script:ScriptPath -Action status

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*ACTIVE*' } -Exactly 1
        }
    }

    Context 'Profile does not exist' {

        It 'reports NOT installed' {
            Mock Test-Path     { $false }
            Mock Select-String { $false }
            Mock Write-Host    {}

            . $script:ScriptPath -Action status

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*NOT*' } -Exactly 1
        }
    }

    Context 'Profile exists but marker is absent' {

        It 'reports NOT installed' {
            Mock Test-Path     { $true }
            Mock Select-String { $false }
            Mock Write-Host    {}

            . $script:ScriptPath -Action status

            Should -Invoke Write-Host -ParameterFilter { $Object -like '*NOT*' } -Exactly 1
        }
    }
}