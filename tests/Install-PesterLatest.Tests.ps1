#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for src/installers/Install-PesterLatest.ps1.
#>
Set-StrictMode -Version Latest

BeforeAll {
    $script:ScriptPath  = Resolve-Path "$PSScriptRoot\..\src\installers\Install-PesterLatest.ps1"
    $script:FakeVersion = '5.99.0'
    $script:FakeRelease = [PSCustomObject]@{ tag_name = "v$($script:FakeVersion)" }
    $script:FakePsd1    = [PSCustomObject]@{ FullName = "C:\Temp\extract\lib\Pester.psd1" }

    # Helper available to ALL It blocks in this file
    function script:Set-HappyPathMocks {
        Mock Invoke-RestMethod { $script:FakeRelease }
        Mock Test-Path         { $true }
        Mock Invoke-WebRequest {}
        Mock Copy-Item         {}
        Mock Expand-Archive    {}
        Mock Get-ChildItem     { $script:FakePsd1 }
        Mock New-Item          {}
        Mock Remove-Item       {}
        Mock Write-Host        {}
        Mock Write-Warning     {}
    }
}

Describe 'Install-PesterLatest - idempotency (already installed)' {

    Context 'Existing installation is valid' {

        It 'returns early without downloading' {
            Mock Invoke-RestMethod { $script:FakeRelease }
            Mock Test-Path         { $true }
            Mock Import-Module     {}
            Mock Invoke-WebRequest {}
            Mock Write-Host        {}
            Mock Write-Warning     {}

            { . $script:ScriptPath } | Should -Not -Throw

            Should -Invoke Invoke-WebRequest -Exactly 0
        }

        It 'imports from the existing psd1 path' {
            Mock Invoke-RestMethod { $script:FakeRelease }
            Mock Test-Path         { $true }
            Mock Import-Module     {}
            Mock Write-Host        {}
            Mock Write-Warning     {}

            . $script:ScriptPath

            Should -Invoke Import-Module -ParameterFilter { $Name -like '*Pester*' } -Times 1 -Scope It
        }
    }

    Context 'Existing installation is invalid - fresh install runs' {

        It 'removes broken directory and reinstalls' {
            Set-HappyPathMocks
            $script:_ic = 0
            Mock Import-Module { $script:_ic++; if ($script:_ic -eq 1) { throw 'broken' } }
            Mock Remove-Item {}

            { . $script:ScriptPath } | Should -Not -Throw

            Should -Invoke Remove-Item -Times 1 -Scope It
        }
    }
}

Describe 'Install-PesterLatest - error paths' {

    Context 'GitHub API unreachable' {
        It 'throws with informative message' {
            Mock Invoke-RestMethod { throw 'network error' }
            Mock Write-Host        {}
            Mock Write-Warning     {}
            { . $script:ScriptPath } | Should -Throw '*Unable to determine latest Pester version*'
        }
    }

    Context 'Pester.psd1 not found in nupkg' {
        It 'throws with informative message' {
            Mock Invoke-RestMethod { $script:FakeRelease }
            Mock Test-Path         { $true }
            Mock Test-Path         { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
            Mock Import-Module     {}
            Mock Invoke-WebRequest {}
            Mock Copy-Item         {}
            Mock Expand-Archive    {}
            Mock Get-ChildItem     { $null }
            Mock New-Item          {}
            Mock Remove-Item       {}
            Mock Write-Host        {}
            Mock Write-Warning     {}
            { . $script:ScriptPath } | Should -Throw '*Could not locate Pester.psd1*'
        }
    }

    Context 'Final Import-Module verification fails' {

        It 'throws with informative message' {
            Set-HappyPathMocks
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
            Mock Import-Module { throw 'corrupt' }
            { . $script:ScriptPath } | Should -Throw '*Installed Pester module failed to import*'
        }

        It 'runs finally-block cleanup on failure' {
            Set-HappyPathMocks
            Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
            Mock Import-Module { throw 'corrupt' }
            { . $script:ScriptPath } | Should -Throw
            Should -Invoke Remove-Item -Times 1 -Scope It
        }
    }
}

Describe 'Install-PesterLatest - fresh install happy path' {

    It 'queries GitHub API for latest version' {
        Set-HappyPathMocks
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
        Mock Import-Module {}
        . $script:ScriptPath
        Should -Invoke Invoke-RestMethod -Exactly 1
    }

    It 'downloads nupkg from PowerShell Gallery' {
        Set-HappyPathMocks
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
        Mock Import-Module {}
        . $script:ScriptPath
        Should -Invoke Invoke-WebRequest -ParameterFilter {
            $Uri -like '*powershellgallery*' -and $Uri -like "*$($script:FakeVersion)*"
        } -Exactly 1
    }

    It 'extracts the nupkg archive' {
        Set-HappyPathMocks
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
        Mock Import-Module {}
        . $script:ScriptPath
        Should -Invoke Expand-Archive -Exactly 1
    }

    It 'creates versioned target directory' {
        Set-HappyPathMocks
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
        Mock Import-Module {}
        . $script:ScriptPath
        Should -Invoke New-Item -Times 1 -Scope It
    }

    It 'runs final import verification' {
        Set-HappyPathMocks
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
        Mock Import-Module {}
        . $script:ScriptPath
        Should -Invoke Import-Module -ParameterFilter { $Name -like '*Pester*' } -Times 1 -Scope It
    }

    It 'cleans up temp files after success' {
        Set-HappyPathMocks
        Mock Test-Path { $false } -ParameterFilter { $LiteralPath -like '*.psd1' }
        Mock Import-Module {}
        . $script:ScriptPath
        Should -Invoke Remove-Item -Times 1 -Scope It
    }
}
