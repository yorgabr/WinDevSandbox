#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:ScriptPath = Join-Path $PSScriptRoot '..\..\src\util\Copy-ProjectArtifacts.ps1'
    $script:ScriptPath = (Resolve-Path -LiteralPath $script:ScriptPath).Path

    # Dot-source so the entry-point guard ($MyInvocation.InvocationName -eq '.')
    # prevents auto-execution and only the functions are loaded into scope.
    . $script:ScriptPath
}

# ─────────────────────────────────────────────────────────────────────────────
# Regression: char/encoding corruption of path separators (the [char]'' bug)
# ─────────────────────────────────────────────────────────────────────────────
Describe 'Regression :: path separator char conversions' {

    It 'String.Replace([char]92,[char]47) converts backslash to slash' {
        'a\b\c'.Replace([char]92, [char]47) | Should -BeExactly 'a/b/c'
    }

    It 'String.TrimEnd([char]92,[char]47) strips trailing separators' {
        'C:\x'.TrimEnd([char]92, [char]47)  | Should -BeExactly 'C:\x'
        'C:/x/'.TrimEnd([char]92, [char]47)  | Should -BeExactly 'C:/x'
        'C:\x'.TrimEnd([char]92, [char]47)   | Should -BeExactly 'C:\x'
    }

    It 'String.TrimStart([char]47) strips a leading slash' {
        '/dist'.TrimStart([char]47) | Should -BeExactly 'dist'
    }

    It 'ConvertTo-RegexFromGlob does not throw on patterns with separators (was crashing)' {
        { ConvertTo-RegexFromGlob -Pattern '.git/**' }        | Should -Not -Throw
        { ConvertTo-RegexFromGlob -Pattern 'node_modules/**' } | Should -Not -Throw
        { ConvertTo-RegexFromGlob -Pattern 'a\b' }             | Should -Not -Throw
    }

    It 'ConvertTo-IgnoreRegexList does not throw building the hardcoded list (was crashing)' {
        { ConvertTo-IgnoreRegexList -GitignorePath 'X:\does\not\exist' } | Should -Not -Throw
    }
}

Describe 'ConvertTo-RegexFromGlob' {

    It 'returns $null for empty/whitespace patterns' {
        ConvertTo-RegexFromGlob -Pattern ''    | Should -BeNullOrEmpty
        ConvertTo-RegexFromGlob -Pattern '   ' | Should -BeNullOrEmpty
    }

    It 'returns $null for comment lines' {
        ConvertTo-RegexFromGlob -Pattern '# comment' | Should -BeNullOrEmpty
    }

    It 'returns $null for negation patterns and emits verbose' {
        ConvertTo-RegexFromGlob -Pattern '!keep.txt' -Verbose 4>&1 |
            Where-Object { $_ -is [System.Management.Automation.VerboseRecord] } |
            Should -Not -BeNullOrEmpty
        ConvertTo-RegexFromGlob -Pattern '!keep.txt' | Should -BeNullOrEmpty
    }

    It 'returns $null for a pattern that is only a slash' {
        ConvertTo-RegexFromGlob -Pattern '/' | Should -BeNullOrEmpty
    }

    It 'converts a simple file name and matches at any depth' {
        $rx = ConvertTo-RegexFromGlob -Pattern '.gitignore'
        '.gitignore'     | Should -Match $rx
        'src/.gitignore' | Should -Match $rx
        'gitignore'      | Should -Not -Match $rx
    }

    It 'converts single star to a non-slash segment' {
        $rx = ConvertTo-RegexFromGlob -Pattern '*.lock'
        'package.lock'  | Should -Match $rx
        'a/b/file.lock' | Should -Match $rx
        'file.locker'   | Should -Not -Match $rx
    }

    It 'single star does not cross directory boundaries' {
        $rx = ConvertTo-RegexFromGlob -Pattern 'src/*.ps1'
        'src/main.ps1'     | Should -Match $rx
        'src/sub/main.ps1' | Should -Not -Match $rx
    }

    It 'converts globstar (**) to match content under the directory (ASCII token)' {
        $rx = ConvertTo-RegexFromGlob -Pattern 'node_modules/**'
        'node_modules/pkg/index.js' | Should -Match $rx
        'node_modules/file.txt'     | Should -Match $rx
        # Note: the generated regex requires a path segment after the dir,
        # so the bare directory name is intentionally NOT matched.
        'node_modules'              | Should -Not -Match $rx
    }

    It 'converts the question mark to a single non-slash character' {
        $rx = ConvertTo-RegexFromGlob -Pattern 'file?.txt'
        'fileA.txt' | Should -Match $rx
        'file.txt'  | Should -Not -Match $rx
    }

    It 'anchors patterns starting with a slash to the root' {
        $rx = ConvertTo-RegexFromGlob -Pattern '/dist'
        'dist'        | Should -Match $rx
        'dist/app.js' | Should -Match $rx
        'src/dist'    | Should -Not -Match $rx
    }

    It 'normalizes backslashes to forward slashes' {
        $rx = ConvertTo-RegexFromGlob -Pattern 'a\b'
        'a/b' | Should -Match $rx
    }
}

Describe 'Test-IsTextFile' {

    BeforeAll {
        $script:TestRoot = Join-Path $TestDrive 'isTextFile'
        New-Item -ItemType Directory -Path $script:TestRoot -Force | Out-Null
    }

    It 'treats an empty file as text' {
        $f = Join-Path $script:TestRoot 'empty.txt'
        Set-Content -LiteralPath $f -Value '' -NoNewline
        Test-IsTextFile -FileInfo (Get-Item -LiteralPath $f) | Should -BeTrue
    }

    It 'detects a plain text file as text' {
        $f = Join-Path $script:TestRoot 'plain.txt'
        Set-Content -LiteralPath $f -Value 'hello world' -NoNewline
        Test-IsTextFile -FileInfo (Get-Item -LiteralPath $f) | Should -BeTrue
    }

    It 'detects a file with null bytes as binary' {
        $f = Join-Path $script:TestRoot 'binary.bin'
        [System.IO.File]::WriteAllBytes($f, [byte[]](72, 73, 0, 74, 75))
        Test-IsTextFile -FileInfo (Get-Item -LiteralPath $f) | Should -BeFalse
    }

    It 'honors the CheckBytes window (null byte beyond window stays text)' {
        $f = Join-Path $script:TestRoot 'late-null.bin'
        # 600 bytes of 'A' (65) then a single null at the very end.
        $bytes = @(1..600 | ForEach-Object { [byte]65 }) + @([byte]0)
        [System.IO.File]::WriteAllBytes($f, [byte[]]$bytes)
        $info = Get-Item -LiteralPath $f
        Test-IsTextFile -FileInfo $info -CheckBytes 128  | Should -BeTrue
        Test-IsTextFile -FileInfo $info -CheckBytes 1024 | Should -BeFalse
    }

    It 'returns $false and warns when the file cannot be opened' {
        # Simulate an unreadable file by pointing at a non-existent path.
        $fake = [PSCustomObject]@{
            Length   = 10
            FullName = (Join-Path $script:TestRoot 'ghost.bin')
            Name     = 'ghost.bin'
        }
        Test-IsTextFile -FileInfo $fake -WarningAction SilentlyContinue | Should -BeFalse
    }
}

Describe 'Test-ShouldIgnore' {

    It 'returns $true when the path matches a regex in the list' {
        $rx = @( ConvertTo-RegexFromGlob -Pattern 'node_modules/**' )
        Test-ShouldIgnore -RelativePath 'node_modules/pkg/a.js' -RegexList $rx | Should -BeTrue
    }

    It 'returns $false when no regex matches' {
        $rx = @( ConvertTo-RegexFromGlob -Pattern 'node_modules/**' )
        Test-ShouldIgnore -RelativePath 'src/app.js' -RegexList $rx | Should -BeFalse
    }

    It 'returns $false for an empty regex list' {
        Test-ShouldIgnore -RelativePath 'anything.txt' -RegexList @() | Should -BeFalse
    }
}

Describe 'Test-MatchesMask' {

    BeforeAll {
        function New-FakeFile {
            param([string]$Name)
            [PSCustomObject]@{ Name = $Name }
        }
    }

    It 'returns $true when no masks are supplied' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'a.ps1') -RelativePath 'src/a.ps1' `
            -IncludeMask @() -ExcludeMask @() | Should -BeTrue
    }

    It 'returns $false when the file name matches an ExcludeMask' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'app.min.js') -RelativePath 'src/app.min.js' `
            -IncludeMask @() -ExcludeMask @('*.min.js') | Should -BeFalse
    }

    It 'returns $false when the relative path matches an ExcludeMask' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'a.spec.js') -RelativePath 'tests/a.spec.js' `
            -IncludeMask @() -ExcludeMask @('tests/*') | Should -BeFalse
    }

    It 'normalizes backslashes in ExcludeMask' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'a.js') -RelativePath 'tests/a.js' `
            -IncludeMask @() -ExcludeMask @('tests\*') | Should -BeFalse
    }

    It 'returns $true when the file name matches an IncludeMask' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'a.ps1') -RelativePath 'src/a.ps1' `
            -IncludeMask @('*.ps1') -ExcludeMask @() | Should -BeTrue
    }

    It 'returns $false when an IncludeMask is set but the file does not match' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'a.md') -RelativePath 'docs/a.md' `
            -IncludeMask @('*.ps1') -ExcludeMask @() | Should -BeFalse
    }

    It 'evaluates ExcludeMask before IncludeMask' {
        Test-MatchesMask -FileInfo (New-FakeFile -Name 'gen.ps1') -RelativePath 'src/gen.ps1' `
            -IncludeMask @('*.ps1') -ExcludeMask @('gen.ps1') | Should -BeFalse
    }
}

Describe 'Resolve-EncodingObject' {

    It 'resolves  to a non-null System.Text.Encoding' -ForEach @(
        @{ Name = 'UTF8'    }
        @{ Name = 'UTF7'    }
        @{ Name = 'UTF32'   }
        @{ Name = 'ASCII'   }
        @{ Name = 'Unicode' }
        @{ Name = 'Default' }
    ) {
        $enc = Resolve-EncodingObject -Encoding $Name
        $enc | Should -Not -BeNullOrEmpty
        ($enc -is [System.Text.Encoding]) | Should -BeTrue
    }
}

Describe 'ConvertTo-IgnoreRegexList' {

    It 'always returns at least the hardcoded rules' {
        (ConvertTo-IgnoreRegexList -GitignorePath 'X:\does\not\exist').Count |
            Should -BeGreaterThan 0
    }

    It 'appends extra excludes' {
        $base  = (ConvertTo-IgnoreRegexList -GitignorePath 'X:\nope').Count
        $extra = (ConvertTo-IgnoreRegexList -GitignorePath 'X:\nope' -ExtraExcludes @('foo/*')).Count
        $extra | Should -BeGreaterThan $base
    }

    It 'reads and merges rules from an existing .gitignore' {
        $gi = Join-Path $TestDrive '.gitignore'
        @('# a comment', '', 'secret.txt', 'logs/**') |
            Set-Content -LiteralPath $gi -Encoding UTF8

        $list = ConvertTo-IgnoreRegexList -GitignorePath $gi
        @($list | Where-Object { 'secret.txt'   -match $_ }).Count | Should -BeGreaterThan 0
        @($list | Where-Object { 'logs/a/b.log' -match $_ }).Count | Should -BeGreaterThan 0
    }
}

Describe 'Invoke-ProjectArtifactCopy (integration)' {

    BeforeEach {
        # Always mock the clipboard so no test touches the real one,
        # even when -WhatIf is NOT supplied.
        Mock -CommandName Set-Clipboard -MockWith { }

        $script:Sandbox = Join-Path $TestDrive ([System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Sandbox -Force | Out-Null
    }

    It 'throws when RootPath does not exist' {
        { Invoke-ProjectArtifactCopy -RootPath 'X:\definitely\missing' -WhatIf } |
            Should -Throw -ExpectedMessage '*does not exist*'
    }

    It 'reports no files when the directory is empty' {
        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -WhatIf
        $stats.Processed | Should -Be 0
        $stats.Output    | Should -BeNullOrEmpty
    }

    It 'normalizes a RootPath with a trailing separator (regression)' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'a.txt') -Value 'alpha'
        $rootWithSlash = $script:Sandbox + ''
        { Invoke-ProjectArtifactCopy -RootPath $rootWithSlash -WhatIf } | Should -Not -Throw

        $stats = Invoke-ProjectArtifactCopy -RootPath $rootWithSlash -WhatIf
        $stats.Processed | Should -Be 1
        $stats.Output    | Should -Match '=== a.txt ==='
    }

    It 'includes plain text files and builds output with headers' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'a.txt') -Value 'alpha'
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'b.md')  -Value 'beta'

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -WhatIf
        $stats.Processed | Should -Be 2
        $stats.Output    | Should -Match '=== a.txt ==='
        $stats.Output    | Should -Match '=== b.md ==='
        $stats.Output    | Should -Match 'alpha'
    }

    It 'uses forward slashes in nested relative paths (regression)' {
        $sub = Join-Path $script:Sandbox 'src'
        New-Item -ItemType Directory -Path $sub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $sub 'deep.txt') -Value 'x'

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -WhatIf
        $stats.Output | Should -Match '=== src/deep.txt ==='
        $stats.Output | Should -Not -Match '=== src\\deep.txt ==='
    }

    It 'filters by IncludeMask' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'keep.ps1') -Value 'code'
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'drop.txt') -Value 'text'

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -IncludeMask '*.ps1' -WhatIf
        $stats.Processed | Should -Be 1
        $stats.Output    | Should -Match 'keep.ps1'
        $stats.Output    | Should -Not -Match 'drop.txt'
    }

    It 'filters by ExcludeMask' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'a.txt')    -Value 'a'
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'a.min.js') -Value 'b'

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -ExcludeMask '*.min.js' -WhatIf
        $stats.Output | Should -Not -Match 'a.min.js'
        $stats.Output | Should -Match 'a.txt'
    }

    It 'skips binary files' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'good.txt') -Value 'ok'
        [System.IO.File]::WriteAllBytes(
            (Join-Path $script:Sandbox 'bin.dat'), [byte[]](1, 2, 0, 3, 4))

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -WhatIf
        $stats.Binary    | Should -Be 1
        $stats.Processed | Should -Be 1
        $stats.Output    | Should -Not -Match 'bin.dat'
    }

    It 'skips files larger than MaxFileSizeKB' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'big.txt') -Value ('x' * 4096)

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox `
                    -MaxFileSizeKB 1 -WhatIf -WarningAction SilentlyContinue
        $stats.TooLarge  | Should -Be 1
        $stats.Processed | Should -Be 0
    }

    It 'honors .gitignore rules' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox '.gitignore') -Value 'ignored.txt' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'ignored.txt') -Value 'no'
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'kept.txt')    -Value 'yes'

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -WhatIf
        $stats.Ignored | Should -BeGreaterThan 0
        $stats.Output  | Should -Match 'kept.txt'
        $stats.Output  | Should -Not -Match '=== ignored.txt ==='
    }

    It 'stops when MaxTotalSizeKB is reached' {
        1..5 | ForEach-Object {
            Set-Content -LiteralPath (Join-Path $script:Sandbox "f$_.txt") -Value ('y' * 800)
        }

        $stats = Invoke-ProjectArtifactCopy -RootPath $script:Sandbox `
                    -MaxTotalSizeKB 1 -WhatIf -WarningAction SilentlyContinue
        $stats.LimitReached | Should -BeTrue
        $stats.Processed    | Should -BeLessThan 5
    }

    It 'does NOT call Set-Clipboard under -WhatIf' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'a.txt') -Value 'a'
        Invoke-ProjectArtifactCopy -RootPath $script:Sandbox -WhatIf | Out-Null
        Should -Invoke -CommandName Set-Clipboard -Times 0 -Exactly
    }

    It 'DOES call Set-Clipboard when committing (no -WhatIf)' {
        Set-Content -LiteralPath (Join-Path $script:Sandbox 'a.txt') -Value 'a'
        Invoke-ProjectArtifactCopy -RootPath $script:Sandbox | Out-Null
        Should -Invoke -CommandName Set-Clipboard -Times 1 -Exactly
    }

    It 'does not call Set-Clipboard when there is nothing to copy' {
        Invoke-ProjectArtifactCopy -RootPath $script:Sandbox | Out-Null
        Should -Invoke -CommandName Set-Clipboard -Times 0 -Exactly
    }
}