BeforeAll {
    # Dot-source so we get the functions without running the main block. -Repository is mandatory,
    # so it gets a value here; the tests pass their own to each function.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Set-RepoGovernance.ps1') -Repository 'octo-org/demo'
    $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:policyPath = Join-Path -Path $script:repoRoot -ChildPath 'governance' -AdditionalChildPath 'policy.json'
    $script:scriptPath = Join-Path -Path $script:repoRoot -ChildPath 'scripts' -AdditionalChildPath 'Set-RepoGovernance.ps1'
    $script:policy = Get-GovernancePolicy -Path $script:policyPath
    $script:rulesetJson = Get-RulesetJson -PolicyPath $script:policyPath -Policy $script:policy
    $script:repo = 'octo-org/demo'
    $script:rulesetList = "repos/$script:repo/rulesets?includes_parents=false&per_page=100"

    # What Invoke-Cli returns: an exit code and the combined output.
    function Get-FakeResult {
        param([int] $ExitCode = 0, [string] $Output = '')
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }

    # Each gh call as one line, 'METHOD endpoint', in the order they were made.
    function Get-CallLine {
        $script:calls | ForEach-Object { "$($_.Arguments[2]) $($_.Arguments[3])" }
    }

    # A copy of the policy with every security feature switched off.
    function Get-PolicyWithoutSecurityFeature {
        $copy = Get-Content -Path $script:policyPath -Raw | ConvertFrom-Json
        foreach ($property in $copy.securityFeatures.PSObject.Properties) {
            $property.Value = $false
        }
        $copy
    }
}

Describe 'Get-HttpStatus' {
    It 'reads the status from gh''s error line' {
        Get-HttpStatus -Output 'gh: Not Found (HTTP 404)' | Should -Be 404
        Get-HttpStatus -Output "{`"message`":`"Upgrade to GitHub Pro`"}`ngh: Upgrade to GitHub Pro (HTTP 403)" | Should -Be 403
    }

    It 'returns nothing when there is no status, e.g. a network error' {
        Get-HttpStatus -Output 'error connecting to api.github.com' | Should -BeNullOrEmpty
        Get-HttpStatus -Output '' | Should -BeNullOrEmpty
    }
}

Describe 'Build-RepoSettingsPayload' {
    It 'is policy.repoSettings, every key and value as they are' {
        $payload = Build-RepoSettingsPayload -Policy $script:policy
        @($payload.Keys) | Should -Be @($script:policy.repoSettings.PSObject.Properties.Name)
        foreach ($property in $script:policy.repoSettings.PSObject.Properties) {
            $payload[$property.Name] | Should -Be $property.Value -Because $property.Name
        }
    }
}

Describe 'Build-SecurityAnalysisPayload' {
    It 'enables secret scanning and push protection when the policy does' {
        Build-SecurityAnalysisPayload -Policy $script:policy | ConvertTo-Json -Depth 10 -Compress |
            Should -Be '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
    }

    It 'is $null when the policy enables neither' {
        Build-SecurityAnalysisPayload -Policy (Get-PolicyWithoutSecurityFeature) | Should -BeNullOrEmpty
    }
}

Describe 'Get-RulesetJson' {
    It 'reads policy.rulesetPath relative to the repository root, as text' {
        $expected = Get-Content -Path (Join-Path -Path $script:repoRoot -ChildPath $script:policy.rulesetPath) -Raw
        $script:rulesetJson | Should -BeExactly $expected
        ($script:rulesetJson | ConvertFrom-Json).name | Should -Be 'protect-default-branch'
    }

    It 'throws when the ruleset file is missing' {
        $policyPath = Join-Path -Path $TestDrive -ChildPath 'governance' -AdditionalChildPath 'policy.json'
        New-Item -ItemType Directory -Path (Split-Path -Path $policyPath -Parent) -Force | Out-Null
        { Get-RulesetJson -PolicyPath $policyPath -Policy $script:policy } | Should -Throw '*Ruleset file not found*'
    }

    It 'throws when the ruleset has no name, since it is found by name' {
        $policyPath = Join-Path -Path $TestDrive -ChildPath 'governance' -AdditionalChildPath 'policy.json'
        $rulesetPath = Join-Path -Path $TestDrive -ChildPath $script:policy.rulesetPath
        New-Item -ItemType Directory -Path (Split-Path -Path $rulesetPath -Parent) -Force | Out-Null
        Set-Content -Path $rulesetPath -Value '{"target":"branch"}'
        { Get-RulesetJson -PolicyPath $policyPath -Policy $script:policy } | Should -Throw '*has no name*'
    }
}

Describe 'Invoke-RepoGovernance' {
    BeforeEach {
        # Every call is recorded. The ruleset list is empty unless a test says otherwise; the rest succeeds.
        $script:calls = [System.Collections.Generic.List[object]]::new()
        $script:rulesets = '[]'
        Mock Invoke-Cli {
            $script:calls.Add([pscustomobject] @{ Name = $Name; Arguments = $Arguments; InputText = $InputText })
            if ($Arguments[3] -eq $script:rulesetList) {
                return Get-FakeResult -Output $script:rulesets
            }
            Get-FakeResult
        }
    }

    It 'applies every part of the policy, in order, with these exact gh calls' {
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        Get-CallLine | Should -Be @(
            'PATCH repos/octo-org/demo'
            'PUT repos/octo-org/demo/vulnerability-alerts'
            'PUT repos/octo-org/demo/automated-security-fixes'
            'PATCH repos/octo-org/demo'
            'PUT repos/octo-org/demo/private-vulnerability-reporting'
            "GET $script:rulesetList"
            'POST repos/octo-org/demo/rulesets'
        )
        $script:calls | ForEach-Object { $_.Name | Should -Be 'gh'; $_.Arguments[0..1] -join ' ' | Should -Be 'api --method' }
    }

    It 'sends the bodies on stdin with --input -, and only for the calls that have one' {
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        foreach ($call in $script:calls) {
            $hasBody = $call.Arguments[2] -in 'PATCH', 'POST'
            ($call.Arguments.Count -eq 6 -and ($call.Arguments[4..5] -join ' ') -eq '--input -') | Should -Be $hasBody
            [bool] $call.InputText | Should -Be $hasBody
        }
    }

    It 'PATCHes the merge settings from policy.repoSettings' {
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        $sent = $script:calls[0].InputText | ConvertFrom-Json
        @($sent.PSObject.Properties.Name) | Should -Be @($script:policy.repoSettings.PSObject.Properties.Name)
        $sent.allow_squash_merge | Should -BeTrue
        $sent.allow_merge_commit | Should -BeFalse
        $sent.allow_rebase_merge | Should -BeFalse
        $sent.delete_branch_on_merge | Should -BeTrue
        $sent.squash_merge_commit_title | Should -Be 'PR_TITLE'
    }

    It 'PATCHes secret scanning and push protection on their own' {
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        $script:calls[3].InputText |
            Should -Be '{"security_and_analysis":{"secret_scanning":{"status":"enabled"},"secret_scanning_push_protection":{"status":"enabled"}}}'
    }

    It 'creates the ruleset with POST, sending the ruleset file unchanged, when none has its name' {
        $script:rulesets = '[{"id":7,"name":"release-tags","source_type":"Repository"}]'
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        $post = @($script:calls | Where-Object { $_.Arguments[2] -eq 'POST' })
        $post.Count | Should -Be 1
        $post[0].Arguments[3] | Should -Be 'repos/octo-org/demo/rulesets'
        $post[0].InputText | Should -BeExactly $script:rulesetJson
        @($script:calls | Where-Object { $_.Arguments[3] -like '*/rulesets/*' }).Count | Should -Be 0
    }

    It 'updates the ruleset with that name in place, with PUT on its id' {
        $script:rulesets = '[{"id":7,"name":"release-tags"},{"id":42,"name":"protect-default-branch"}]'
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        $put = @($script:calls | Where-Object { $_.Arguments[3] -like '*/rulesets/*' })
        $put.Count | Should -Be 1
        ($put[0].Arguments -join ' ') | Should -Be 'api --method PUT repos/octo-org/demo/rulesets/42 --input -'
        $put[0].InputText | Should -BeExactly $script:rulesetJson
        @($script:calls | Where-Object { $_.Arguments[2] -eq 'POST' }).Count | Should -Be 0
    }

    It 'is idempotent: a second run sends the same calls and updates rather than creating a second ruleset' {
        $script:rulesets = '[{"id":42,"name":"protect-default-branch"}]'
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        $first = @(Get-CallLine)
        $script:calls.Clear()
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore
        @(Get-CallLine) | Should -Be $first
        $first | Should -Contain 'PUT repos/octo-org/demo/rulesets/42'
        $first | Should -Not -Contain 'POST repos/octo-org/demo/rulesets'
    }

    It 'with -WhatIf, only reads (to say create or update) and writes nothing' {
        $script:rulesets = '[{"id":42,"name":"protect-default-branch"}]'
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -WhatIf -InformationAction Ignore
        @(Get-CallLine) | Should -Be @("GET $script:rulesetList")
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments[2] -ne 'GET' -or $InputText }
    }

    It 'skips the security calls the policy switches off' {
        Invoke-RepoGovernance -Repository $script:repo -Policy (Get-PolicyWithoutSecurityFeature) -RulesetJson $script:rulesetJson -InformationAction Ignore
        @(Get-CallLine) | Should -Be @('PATCH repos/octo-org/demo', "GET $script:rulesetList", 'POST repos/octo-org/demo/rulesets')
    }

    It 'warns and carries on when rulesets are refused on a private repository (HTTP 403)' {
        Mock Invoke-Cli {
            $script:calls.Add([pscustomobject] @{ Name = $Name; Arguments = $Arguments; InputText = $InputText })
            Get-FakeResult -ExitCode 1 -Output "{`"message`":`"Upgrade to GitHub Pro or make this repository public to enable this feature.`"}`ngh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)"
        } -ParameterFilter { $Arguments[3] -eq $script:rulesetList }
        # No throw: a throw would fail the test here.
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson `
            -InformationAction Ignore -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 1
        # GitHub's own reason, without gh's prefix and the repeated status, then what to do about it.
        "$($warnings[0])" | Should -BeLike ("Skipped ruleset 'protect-default-branch' on octo-org/demo: GitHub answered HTTP 403 " +
            '(Upgrade to GitHub Pro or make this repository public to enable this feature.). On a private repository*')
        @($script:calls | Where-Object { $_.Arguments[2] -in 'POST', 'PUT' -and $_.Arguments[3] -like '*rulesets*' }).Count | Should -Be 0
    }

    It 'warns on HTTP <Status> for the plan-gated <Method> <Endpoint> and still applies the ruleset' -ForEach @(
        @{ Status = 422; Method = 'PATCH'; Endpoint = 'repos/octo-org/demo'; Feature = 'secret scanning' }
        @{ Status = 403; Method = 'PATCH'; Endpoint = 'repos/octo-org/demo'; Feature = 'secret scanning' }
        @{ Status = 404; Method = 'PUT'; Endpoint = 'repos/octo-org/demo/private-vulnerability-reporting'; Feature = 'private vulnerability reporting' }
        @{ Status = 403; Method = 'POST'; Endpoint = 'repos/octo-org/demo/rulesets'; Feature = 'ruleset' }
    ) {
        # Only the gated call fails; the settings PATCH (the one without security_and_analysis) succeeds.
        # Script variables, not $Method and $Endpoint: in the filter those would be Invoke-GitHubApi's own parameters.
        $script:gated = @{ Status = $Status; Method = $Method; Endpoint = $Endpoint }
        Mock Invoke-Cli {
            $script:calls.Add([pscustomobject] @{ Name = $Name; Arguments = $Arguments; InputText = $InputText })
            Get-FakeResult -ExitCode 1 -Output "gh: Refused (HTTP $($script:gated.Status))"
        } -ParameterFilter {
            $Arguments[2] -eq $script:gated.Method -and $Arguments[3] -eq $script:gated.Endpoint -and
            ($script:gated.Method -ne 'PATCH' -or $InputText -like '*security_and_analysis*')
        }
        Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson `
            -InformationAction Ignore -WarningVariable warnings -WarningAction SilentlyContinue
        $warnings.Count | Should -Be 1
        "$($warnings[0])" | Should -BeLike "Skipped $Feature*HTTP $Status*"
        Get-CallLine | Select-Object -Last 1 | Should -Be 'POST repos/octo-org/demo/rulesets'
    }

    It 'stops with an error when the merge settings PATCH fails, even with 404: that is not a plan limit' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'gh: Not Found (HTTP 404)' } -ParameterFilter { $Arguments[2] -eq 'PATCH' }
        { Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore } |
            Should -Throw '*repository settings failed (PATCH repos/octo-org/demo, exit 1): gh: Not Found (HTTP 404)*'
        Should -Invoke Invoke-Cli -Times 1 -Exactly
    }

    It 'stops with an error when enabling vulnerability alerts fails' {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output 'gh: Forbidden (HTTP 403)' } -ParameterFilter { $Arguments[3] -like '*/vulnerability-alerts' }
        { Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore } |
            Should -Throw '*Dependabot vulnerability alerts failed*'
    }

    It 'stops with an error on a plan-gated feature when the failure is not a plan answer (HTTP 500 or no status)' -ForEach @(
        @{ Output = 'gh: Server Error (HTTP 500)' }
        @{ Output = 'error connecting to api.github.com' }
    ) {
        Mock Invoke-Cli { Get-FakeResult -ExitCode 1 -Output $Output } -ParameterFilter { $Arguments[3] -eq $script:rulesetList }
        { Invoke-RepoGovernance -Repository $script:repo -Policy $script:policy -RulesetJson $script:rulesetJson -InformationAction Ignore } |
            Should -Throw "*Listing the rulesets of octo-org/demo failed (exit 1): $Output*"
    }

    It 'rejects a bad repository name before calling gh' -ForEach @(
        @{ Repository = 'demo' }
        @{ Repository = 'octo-org/demo; rm -rf /' }
        @{ Repository = '../octo-org/demo' }
    ) {
        { Invoke-RepoGovernance -Repository $Repository -Policy $script:policy -RulesetJson $script:rulesetJson } |
            Should -Throw '*Repository must look like owner/name*'
        Should -Invoke Invoke-Cli -Times 0 -Exactly
    }
}

Describe 'Set-RepoGovernance.ps1 main block' {
    It 'exits 1 with a message for a bad repository name, before calling gh' {
        $pwsh = (Get-Process -Id $PID).Path
        $output = & $pwsh -NoProfile -File $script:scriptPath -Repository 'not a repository' 2>&1
        $LASTEXITCODE | Should -Be 1
        "$output" | Should -BeLike '*Repository must look like owner/name*'
    }
}
