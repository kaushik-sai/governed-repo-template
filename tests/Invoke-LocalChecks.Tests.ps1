BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Invoke-LocalChecks.ps1')
    $script:scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Invoke-LocalChecks.ps1'

    function Get-FakeResult {
        param([int] $ExitCode = 0, [string] $Output = '')
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }
}

Describe 'Invoke-LocalCheck' {
    BeforeEach {
        # By default every tool and module is installed and passes.
        Mock Test-ToolInstalled { $true }
        Mock Test-ModuleInstalled { $true }
        Mock Invoke-LocalTool { Get-FakeResult }
    }

    It 'runs the five checks in order and passes them' {
        $r = @(Invoke-LocalCheck)
        ($r.Check -join ',') | Should -Be 'lint,test,actionlint,zizmor,gitleaks'
        @($r | Where-Object Status -ne 'Pass').Count | Should -Be 0
        Should -Invoke Invoke-LocalTool -Times 5 -Exactly
    }

    It 'reports a failing tool as Fail with its output' {
        Mock Invoke-LocalTool { Get-FakeResult -ExitCode 1 -Output 'bad workflow' } -ParameterFilter { $Name -eq 'actionlint' }
        $row = @(Invoke-LocalCheck) | Where-Object Check -eq 'actionlint'
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -Match 'bad workflow'
    }

    It 'reports a missing tool as Skip with the install hint and does not run it' {
        Mock Test-ToolInstalled { $Name -ne 'zizmor' }
        $row = @(Invoke-LocalCheck) | Where-Object Check -eq 'zizmor'
        $row.Status | Should -Be 'Skip'
        $row.Detail | Should -Match 'not installed.*Install:'
        Should -Invoke Invoke-LocalTool -Times 0 -Exactly -ParameterFilter { $Name -eq 'zizmor' }
    }

    It 'reports a missing module as Skip' {
        Mock Test-ModuleInstalled { $Name -ne 'Pester' }
        (@(Invoke-LocalCheck) | Where-Object Check -eq 'test').Status | Should -Be 'Skip'
    }

    It 'skips what -Skip names' {
        $r = @(Invoke-LocalCheck -Skip 'gitleaks', 'lint')
        (@($r | Where-Object Status -eq 'Skip').Check -join ',') | Should -Be 'lint,gitleaks'
        Should -Invoke Invoke-LocalTool -Times 3 -Exactly
    }
}

Describe 'Invoke-LocalChecks.ps1 as a command' {
    It 'rejects an unknown check name' {
        $null = & pwsh -NoProfile -File $script:scriptPath -Skip nope 2>&1
        $LASTEXITCODE | Should -Not -Be 0
    }

    It 'exits 0 with every check skipped' {
        $out = & pwsh -NoProfile -Command "& '$($script:scriptPath)' -Skip lint,test,actionlint,zizmor,gitleaks" 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'No check failed \(5 skipped\)'
    }
}
