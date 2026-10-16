BeforeAll {
    # Dot-source so we get the functions without running the main block. -Name is mandatory,
    # so it gets a value here; the tests pass their own to each function.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'New-GovernedRepo.ps1') -Name 'octo-org/new-svc'
    $script:scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'New-GovernedRepo.ps1'
    $script:template = 'kaushik-sai/governed-repo-template'

    # What Invoke-Cli returns: an exit code and the combined output.
    function Get-FakeResult {
        param([int] $ExitCode = 0, [string] $Output = '')
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }

    # A stand-in for Set-RepoGovernance.ps1: writes its arguments to a file and exits with a given code.
    function Initialize-FakeGovernanceScript {
        param([int] $ExitCode = 0)
        $path = Join-Path -Path $TestDrive -ChildPath "Fake-SetRepoGovernance-$ExitCode.ps1"
        $log = Join-Path -Path $TestDrive -ChildPath "fake-$ExitCode.log"
        Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue
        Set-Content -LiteralPath $path -Value @"
param([string] `$Repository)
Set-Content -LiteralPath '$log' -Value "Repository=`$Repository"
exit $ExitCode
"@
        [pscustomobject] @{ Path = $path; Log = $log }
    }
}

Describe 'Get-RepoCreateArgument' {
    It 'creates the repository from the template with the visibility as a flag' {
        $arguments = Get-RepoCreateArgument -Name 'octo-org/new-svc' -Template $script:template -Visibility private
        ($arguments -join ' ') | Should -Be 'repo create octo-org/new-svc --template kaushik-sai/governed-repo-template --private'
    }

    It 'passes the description as one argument, spaces and all' {
        $arguments = @(Get-RepoCreateArgument -Name 'octo-org/new-svc' -Template $script:template -Visibility public -Description 'Orders API; "v2"')
        $arguments | Should -Be @('repo', 'create', 'octo-org/new-svc', '--template', $script:template, '--public', '--description', 'Orders API; "v2"')
    }

    It 'accepts only private, public or internal' {
        { Get-RepoCreateArgument -Name 'octo-org/new-svc' -Template $script:template -Visibility secret } | Should -Throw
    }
}

Describe 'Invoke-NewGovernedRepo' {
    BeforeEach {
        # By default the repository does not exist yet, and creating it succeeds.
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'GraphQL: Could not resolve to a Repository' } -ParameterFilter { $Arguments[1] -eq 'view' }
        Mock Invoke-Cli { Get-FakeResult -Output 'https://github.com/octo-org/new-svc' } -ParameterFilter { $Arguments[1] -eq 'create' }
        Mock Invoke-SetRepoGovernance { 0 }
    }

    It 'checks the name is free, creates the repository, then governs it' {
        Invoke-NewGovernedRepo -Name 'octo-org/new-svc' -Template $script:template -Visibility private -Description 'Orders API' -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter { $Name -eq 'gh' -and ($Arguments -join ' ') -eq 'repo view octo-org/new-svc --json name' }
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'gh' -and
            ($Arguments -join '|') -eq 'repo|create|octo-org/new-svc|--template|kaushik-sai/governed-repo-template|--private|--description|Orders API'
        }
        Should -Invoke Invoke-SetRepoGovernance -Times 1 -Exactly -ParameterFilter { $Repository -eq 'octo-org/new-svc' }
    }

    It 'stops when the repository already exists, creating and changing nothing' {
        Mock Invoke-Cli { Get-FakeResult -Output '{"name":"new-svc"}' } -ParameterFilter { $Arguments[1] -eq 'view' }
        { Invoke-NewGovernedRepo -Name 'octo-org/new-svc' -Template $script:template -Visibility private } |
            Should -Throw '*octo-org/new-svc already exists*'
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[1] -eq 'create' }
        Should -Invoke Invoke-SetRepoGovernance -Times 0 -Exactly
    }

    It 'stops with gh''s message when gh repo create fails, without governing anything' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'HTTP 422: Name already exists on this account' } -ParameterFilter { $Arguments[1] -eq 'create' }
        { Invoke-NewGovernedRepo -Name 'octo-org/new-svc' -Template $script:template -Visibility private -InformationAction Ignore } |
            Should -Throw '*gh repo create octo-org/new-svc failed (exit 1): HTTP 422: Name already exists*'
        Should -Invoke Invoke-SetRepoGovernance -Times 0 -Exactly
    }

    It 'says the repository was created and how to finish when governance fails' {
        Mock Invoke-SetRepoGovernance { 1 }
        { Invoke-NewGovernedRepo -Name 'octo-org/new-svc' -Template $script:template -Visibility private -InformationAction Ignore } |
            Should -Throw '*octo-org/new-svc was created, but governance failed (exit 1)*Set-RepoGovernance.ps1 -Repository octo-org/new-svc*'
    }

    It 'rejects a bad <Which> name before calling gh' -ForEach @(
        @{ Which = 'repository'; Repo = 'new-svc'; Template = 'kaushik-sai/governed-repo-template' }
        @{ Which = 'template'; Repo = 'octo-org/new-svc'; Template = 'https://github.com/x/y' }
    ) {
        { Invoke-NewGovernedRepo -Name $Repo -Template $Template -Visibility private } | Should -Throw '*Repository must look like owner/name*'
        Should -Invoke Invoke-Cli -Times 0 -Exactly
    }
}

Describe 'Invoke-NewGovernedRepo -WhatIf' {
    It 'only looks the name up: creates nothing and runs no governance' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'GraphQL: Could not resolve to a Repository' }
        # Invoke-SetRepoGovernance is not mocked: the real one must skip the script under -WhatIf.
        # A local default points it at a stand-in, so even a bug here could never reach GitHub.
        $fake = Initialize-FakeGovernanceScript
        $PSDefaultParameterValues = @{ 'Invoke-SetRepoGovernance:ScriptPath' = $fake.Path }
        Invoke-NewGovernedRepo -Name 'octo-org/new-svc' -Template $script:template -Visibility public -WhatIf -InformationAction Ignore
        Should -Invoke Invoke-Cli -Times 1 -Exactly
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq 'repo view octo-org/new-svc --json name' }
        Test-Path -LiteralPath $fake.Log | Should -BeFalse
    }

    It 'without -WhatIf, runs the governance script (so the test above can tell the difference)' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 } -ParameterFilter { $Arguments[1] -eq 'view' }
        Mock Invoke-Cli { Get-FakeResult } -ParameterFilter { $Arguments[1] -eq 'create' }
        $fake = Initialize-FakeGovernanceScript
        $PSDefaultParameterValues = @{ 'Invoke-SetRepoGovernance:ScriptPath' = $fake.Path }
        Invoke-NewGovernedRepo -Name 'octo-org/new-svc' -Template $script:template -Visibility public -InformationAction Ignore 6>$null | Out-Null
        Get-Content -LiteralPath $fake.Log | Should -Be 'Repository=octo-org/new-svc'
    }
}

Describe 'Invoke-SetRepoGovernance' {
    It 'runs the governance script for the repository and returns its exit code' -ForEach @(
        @{ ExitCode = 0 }
        @{ ExitCode = 1 }
    ) {
        $fake = Initialize-FakeGovernanceScript -ExitCode $ExitCode
        Invoke-SetRepoGovernance -Repository 'octo-org/new-svc' -ScriptPath $fake.Path | Should -Be $ExitCode
        Get-Content -LiteralPath $fake.Log | Should -Be 'Repository=octo-org/new-svc'
    }

    It 'runs nothing under -WhatIf' {
        $fake = Initialize-FakeGovernanceScript
        Invoke-SetRepoGovernance -Repository 'octo-org/new-svc' -ScriptPath $fake.Path -WhatIf | Should -Be 0
        Test-Path -LiteralPath $fake.Log | Should -BeFalse
    }

    It 'points at Set-RepoGovernance.ps1 next to this script by default' {
        $default = (Get-Command -Name Invoke-SetRepoGovernance).ScriptBlock.Ast.Body.ParamBlock.Parameters |
            Where-Object { $_.Name.VariablePath.UserPath -eq 'ScriptPath' }
        "$($default.DefaultValue)" | Should -BeLike "*'Set-RepoGovernance.ps1'*"
        Test-Path -LiteralPath (Join-Path -Path (Split-Path -Path $script:scriptPath -Parent) -ChildPath 'Set-RepoGovernance.ps1') | Should -BeTrue
    }
}

Describe 'Get-NextStep' {
    It 'tells how to clone, set the CODEOWNERS owner and check the result' {
        $text = Get-NextStep -Repository 'octo-org/new-svc'
        $text | Should -BeLike '*gh repo clone octo-org/new-svc; cd new-svc*'
        $text | Should -BeLike '*.github/CODEOWNERS*your GitHub user or team*'
        $text | Should -BeLike '*Test-RepoGovernance.ps1 -Path . -Repository octo-org/new-svc*'
    }
}

Describe 'New-GovernedRepo.ps1 main block' {
    It 'exits 1 with a message for a bad repository name' {
        $pwsh = (Get-Process -Id $PID).Path
        # On a machine without gh this stops one step earlier, also with exit 1; neither calls GitHub.
        $output = & $pwsh -NoProfile -File $script:scriptPath -Name 'not a repository' 2>&1
        $LASTEXITCODE | Should -Be 1
        "$output" | Should -Match 'Repository must look like owner/name|gh is not on PATH'
    }
}
