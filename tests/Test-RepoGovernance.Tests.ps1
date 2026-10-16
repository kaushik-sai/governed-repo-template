BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-RepoGovernance.ps1')
    $script:repoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:scriptPath = Join-Path -Path $script:repoRoot -ChildPath 'scripts' -AdditionalChildPath 'Test-RepoGovernance.ps1'
    $script:policy = Get-GovernancePolicy -Path (Join-Path -Path $script:repoRoot -ChildPath 'governance' -AdditionalChildPath 'policy.json')
    $script:repo = 'octo-org/demo'
    $script:rulesetList = "repos/$script:repo/rulesets?includes_parents=false&per_page=100"

    # What Invoke-Cli returns: an exit code and the combined output.
    function Get-FakeResult {
        param([int] $ExitCode = 0, [string] $Output = '')
        [pscustomobject] @{ ExitCode = $ExitCode; Output = $Output }
    }

    # A governed working tree in $TestDrive: this repository's governance folder, every required
    # file (empty), and workflows whose job ids are the required checks.
    function Initialize-GovernedTree {
        param([string] $Name = 'repo')
        $root = Join-Path -Path $TestDrive -ChildPath $Name
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Path $root | Out-Null
        Copy-Item -Path (Join-Path -Path $script:repoRoot -ChildPath 'governance') -Destination $root -Recurse
        foreach ($file in $script:policy.requiredFiles) {
            $path = Join-Path -Path $root -ChildPath $file
            New-Item -ItemType Directory -Path (Split-Path -Path $path -Parent) -Force | Out-Null
            Set-Content -LiteralPath $path -Value ''
        }
        $workflows = Join-Path -Path $root -ChildPath '.github' -AdditionalChildPath 'workflows'
        Set-Content -LiteralPath (Join-Path -Path $workflows -ChildPath 'ci.yml') -Value @'
name: ci
on:
  pull_request:
jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - run: echo lint
  test:
    runs-on: ubuntu-latest
  workflow-lint:
    runs-on: ubuntu-latest
'@
        Set-Content -LiteralPath (Join-Path -Path $workflows -ChildPath 'security.yml') -Value @'
on: [pull_request]
jobs:
  secret-scan:
    runs-on: ubuntu-latest
  dependency-review:
    runs-on: ubuntu-latest
'@
        Set-Content -LiteralPath (Join-Path -Path $workflows -ChildPath 'pr-policy.yml') -Value @'
on: pull_request
jobs:
  pr-policy:
    runs-on: ubuntu-latest
'@
        $root
    }

    # The live repository as gh api repos/{r} returns it: the policy's settings, public, scanning on.
    function Get-LiveRepoJson {
        param([bool] $Private = $false, [string] $SecretScanning = 'enabled', [hashtable] $Override = @{})
        $repo = [ordered] @{ full_name = $script:repo; private = $Private }
        foreach ($property in $script:policy.repoSettings.PSObject.Properties) {
            $repo[$property.Name] = $property.Value
        }
        foreach ($key in $Override.Keys) {
            $repo[$key] = $Override[$key]
        }
        if ($SecretScanning) {
            $repo['security_and_analysis'] = @{
                secret_scanning                 = @{ status = $SecretScanning }
                secret_scanning_push_protection = @{ status = $SecretScanning }
            }
        }
        $repo | ConvertTo-Json -Depth 10
    }

    # The live ruleset as gh api repos/{r}/rulesets/{id} returns it: the ruleset file plus its id.
    function Get-LiveRulesetJson {
        param([string] $Enforcement = 'active', [string[]] $Contexts = $script:policy.requiredStatusChecks)
        $ruleset = Get-Content -LiteralPath (Join-Path -Path $script:repoRoot -ChildPath $script:policy.rulesetPath) -Raw | ConvertFrom-Json
        $ruleset | Add-Member -NotePropertyName id -NotePropertyValue 42
        $ruleset.enforcement = $Enforcement
        $checks = ($ruleset.rules | Where-Object type -EQ 'required_status_checks').parameters
        $checks.required_status_checks = @($Contexts | ForEach-Object { @{ context = $_; integration_id = 15368 } })
        $ruleset | ConvertTo-Json -Depth 20
    }

    # The rows whose Check matches a pattern.
    function Get-Row {
        param([object[]] $Results, [string] $Like)
        @($Results | Where-Object Check -Like $Like)
    }
}

Describe 'Get-WorkflowJobId' {
    It 'returns the keys one level under jobs:, not steps, options or other top-level keys' {
        $yaml = @'
# comment
name: ci
on:
  push:
    branches: [main]
permissions:
  contents: read
jobs:
  # a comment between jobs
  lint:
    name: Lint
    runs-on: ubuntu-latest
    steps:
      - name: not-a-job
        run: echo hi

  "quoted-job":
    runs-on: ubuntu-latest
  build_2: # trailing comment
    runs-on: ubuntu-latest
concurrency:
  group: ci
'@
        @(Get-WorkflowJobId -Content $yaml) | Should -Be @('lint', 'quoted-job', 'build_2')
    }

    It 'follows the indentation the file uses, e.g. four spaces' {
        $yaml = "jobs:`r`n    test:`r`n        runs-on: ubuntu-latest`r`n    pr-policy:`r`n        runs-on: ubuntu-latest`r`n"
        @(Get-WorkflowJobId -Content $yaml) | Should -Be @('test', 'pr-policy')
    }

    It 'returns nothing when there is no jobs: block' {
        @(Get-WorkflowJobId -Content "name: x`non: push`n").Count | Should -Be 0
        @(Get-WorkflowJobId -Content '').Count | Should -Be 0
    }
}

Describe 'Compare-NameSet' {
    It 'returns nothing for the same names in another order or repeated' {
        Compare-NameSet -Expected @('lint', 'test') -Actual @('test', 'lint', 'test') | Should -BeNullOrEmpty
    }

    It 'names what is missing and what is extra' {
        Compare-NameSet -Expected @('lint', 'test') -Actual @('lint', 'build') | Should -Be 'missing: test; not in policy: build'
        Compare-NameSet -Expected @('lint') -Actual @() | Should -Be 'missing: lint'
    }
}

Describe 'Offline checks' {
    BeforeEach {
        $script:root = Initialize-GovernedTree
        Mock Invoke-Cli { throw 'the offline checks must not call gh' }
    }

    It 'passes every check on a complete governed tree, and skips the online part without -Repository' {
        $results = @(Invoke-GovernanceCheck -Path $script:root -Policy $script:policy)
        $results | Where-Object Status -NE 'Pass' | ForEach-Object { "$($_.Check): $($_.Detail)" } | Should -Be @('Live repository: no -Repository given; offline checks only')
        (Get-Row -Results $results -Like 'Required file *').Count | Should -Be @($script:policy.requiredFiles).Count
        (Get-Row -Results $results -Like 'Workflow job *').Count | Should -Be @($script:policy.requiredStatusChecks).Count
        (Get-Row -Results $results -Like 'Live repository')[0].Status | Should -Be 'Skip'
        Should -Invoke Invoke-Cli -Times 0 -Exactly
    }

    It 'returns one row per check with Check, Status and Detail' {
        $row = @(Invoke-GovernanceCheck -Path $script:root -Policy $script:policy)[0]
        @($row.PSObject.Properties.Name) | Should -Be @('Check', 'Status', 'Detail')
    }

    It 'fails the required file that is missing, and only that one' {
        Remove-Item -LiteralPath (Join-Path -Path $script:root -ChildPath '.github/CODEOWNERS')
        $failed = @(Test-RequiredFile -Path $script:root -Policy $script:policy | Where-Object Status -EQ 'Fail')
        $failed.Count | Should -Be 1
        $failed[0].Check | Should -Be 'Required file .github/CODEOWNERS'
        $failed[0].Detail | Should -Be 'missing'
    }

    It 'fails a required file that is a folder' {
        Remove-Item -LiteralPath (Join-Path -Path $script:root -ChildPath 'LICENSE')
        New-Item -ItemType Directory -Path (Join-Path -Path $script:root -ChildPath 'LICENSE') | Out-Null
        (Get-Row -Results @(Test-RequiredFile -Path $script:root -Policy $script:policy) -Like 'Required file LICENSE')[0].Status | Should -Be 'Fail'
    }

    It 'passes the ruleset file when it requires the policy''s checks in another order' {
        $file = Join-Path -Path $script:root -ChildPath $script:policy.rulesetPath
        $ruleset = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $checks = ($ruleset.rules | Where-Object type -EQ 'required_status_checks').parameters
        [array]::Reverse($checks.required_status_checks)
        $ruleset | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $file
        (Test-RulesetFile -Path $script:root -Policy $script:policy).Status | Should -Be 'Pass'
    }

    It 'fails the ruleset file when its checks differ from the policy, naming the difference' {
        $file = Join-Path -Path $script:root -ChildPath $script:policy.rulesetPath
        (Get-Content -LiteralPath $file -Raw) -replace '"context": "pr-policy"', '"context": "build"' | Set-Content -LiteralPath $file
        $row = Test-RulesetFile -Path $script:root -Policy $script:policy
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -Be 'missing: pr-policy; not in policy: build'
    }

    It 'fails the ruleset file when it is <Case>' -ForEach @(
        @{ Case = 'missing'; Content = $null; Detail = '*is missing' }
        @{ Case = 'not JSON'; Content = '{ not json'; Detail = '*is not valid JSON*' }
        @{ Case = 'without a required_status_checks rule'; Content = '{"name":"x","rules":[{"type":"deletion"}]}'; Detail = 'missing: lint, test, *' }
    ) {
        $file = Join-Path -Path $script:root -ChildPath $script:policy.rulesetPath
        if ($null -eq $Content) { Remove-Item -LiteralPath $file } else { Set-Content -LiteralPath $file -Value $Content }
        $row = Test-RulesetFile -Path $script:root -Policy $script:policy
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -BeLike $Detail
    }

    It 'fails a required check with no workflow job of that id, and finds jobs in .yaml files too' {
        $workflows = Join-Path -Path $script:root -ChildPath '.github/workflows'
        Set-Content -LiteralPath (Join-Path -Path $workflows -ChildPath 'pr-policy.yml') -Value "jobs:`n  title-check:`n    runs-on: ubuntu-latest"
        Set-Content -LiteralPath (Join-Path -Path $workflows -ChildPath 'extra.yaml') -Value "jobs:`n  secret-scan:`n    runs-on: ubuntu-latest"
        Remove-Item -LiteralPath (Join-Path -Path $workflows -ChildPath 'security.yml')
        $rows = @(Test-WorkflowJob -Path $script:root -Policy $script:policy)
        $rows | Where-Object Status -EQ 'Fail' | ForEach-Object Check | Should -Be @('Workflow job dependency-review', 'Workflow job pr-policy')
        (Get-Row -Results $rows -Like 'Workflow job secret-scan')[0].Detail | Should -Be 'job in extra.yaml'
    }

    It 'fails every required check when there is no workflows folder' {
        Remove-Item -LiteralPath (Join-Path -Path $script:root -ChildPath '.github/workflows') -Recurse
        @(Test-WorkflowJob -Path $script:root -Policy $script:policy | Where-Object Status -EQ 'Fail').Count |
            Should -Be @($script:policy.requiredStatusChecks).Count
    }
}

Describe 'Online checks' {
    BeforeEach {
        $script:root = Initialize-GovernedTree
        # Every gh api call is answered from this table, by endpoint; anything else is a 404.
        $script:responses = @{
            "repos/$script:repo"                      = Get-FakeResult -Output (Get-LiveRepoJson)
            "repos/$script:repo/vulnerability-alerts" = Get-FakeResult
            $script:rulesetList                       = Get-FakeResult -Output '[{"id":7,"name":"tags"},{"id":42,"name":"protect-default-branch"}]'
            "repos/$script:repo/rulesets/42"          = Get-FakeResult -Output (Get-LiveRulesetJson)
        }
        Mock Invoke-Cli {
            $response = $script:responses[$Arguments[1]]
            if ($response) { $response } else { Get-FakeResult -ExitCode 1 -Output 'gh: Not Found (HTTP 404)' }
        }
    }

    It 'passes every check for a repository that matches the policy, with read-only calls' {
        $results = @(Invoke-GovernanceCheck -Path $script:root -Policy $script:policy -Repository $script:repo)
        $results | Where-Object Status -NE 'Pass' | ForEach-Object { "$($_.Check): $($_.Detail)" } | Should -BeNullOrEmpty
        (Get-Row -Results $results -Like 'Live setting *').Count | Should -Be @($script:policy.repoSettings.PSObject.Properties).Count
        (Get-Row -Results $results -Like 'Live ruleset protect-default-branch*').Count | Should -Be 3
        # Read-only: plain gh api GETs, no method, no body.
        Should -Invoke Invoke-Cli -Times 4 -Exactly
        Should -Invoke Invoke-Cli -Times 0 -Exactly -ParameterFilter { $Arguments -contains '--method' -or $Arguments -contains '--input' -or $InputText }
        Should -Invoke Invoke-Cli -Times 1 -Exactly -ParameterFilter { $Name -eq 'gh' -and ($Arguments -join ' ') -eq "api $script:rulesetList" }
    }

    It 'fails a live setting that differs from the policy' {
        $script:responses["repos/$script:repo"] = Get-FakeResult -Output (Get-LiveRepoJson -Override @{ allow_merge_commit = $true })
        $row = (Get-Row -Results @(Test-LiveRepository -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch') `
                -Like 'Live setting allow_merge_commit')[0]
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -Be 'is True, policy wants False'
    }

    It 'warns about a setting GitHub does not return (only admins see some)' {
        $json = Get-LiveRepoJson | ConvertFrom-Json
        $json.PSObject.Properties.Remove('squash_merge_commit_title')
        $script:responses["repos/$script:repo"] = Get-FakeResult -Output ($json | ConvertTo-Json -Depth 10)
        $row = (Get-Row -Results @(Test-LiveRepository -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch') `
                -Like 'Live setting squash_merge_commit_title')[0]
        $row.Status | Should -Be 'Warn'
    }

    It 'fails vulnerability alerts when GitHub answers 404 (disabled)' {
        $script:responses.Remove("repos/$script:repo/vulnerability-alerts")
        $row = Test-LiveVulnerabilityAlert -Repository $script:repo -Policy $script:policy
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -BeLike 'disabled*'
    }

    It 'fails vulnerability alerts when they cannot be read for another reason' {
        $script:responses["repos/$script:repo/vulnerability-alerts"] = Get-FakeResult -ExitCode 1 -Output 'gh: Server Error (HTTP 500)'
        (Test-LiveVulnerabilityAlert -Repository $script:repo -Policy $script:policy).Detail | Should -BeLike 'could not read*HTTP 500*'
    }

    It 'warns, not fails, on a private repository where rulesets and secret scanning are not on the plan' {
        $script:responses["repos/$script:repo"] = Get-FakeResult -Output (Get-LiveRepoJson -Private $true -SecretScanning '')
        $script:responses[$script:rulesetList] = Get-FakeResult -ExitCode 1 -Output 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
        $results = @(Test-LiveRepository -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch')
        @($results | Where-Object Status -EQ 'Fail').Count | Should -Be 0
        $results | Where-Object Status -EQ 'Warn' | ForEach-Object Check |
            Should -Be @('Live secret scanning', 'Live push protection', 'Live ruleset protect-default-branch')
        (Get-Row -Results $results -Like 'Live ruleset*')[0].Detail | Should -BeLike '*not available on this private repository*HTTP 403*'
    }

    It 'fails the same refusals on a public repository, where every plan has them' {
        $script:responses["repos/$script:repo"] = Get-FakeResult -Output (Get-LiveRepoJson -SecretScanning 'disabled')
        $script:responses[$script:rulesetList] = Get-FakeResult -ExitCode 1 -Output 'gh: Forbidden (HTTP 403)'
        $results = @(Test-LiveRepository -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch')
        $results | Where-Object Status -EQ 'Fail' | ForEach-Object Check |
            Should -Be @('Live secret scanning', 'Live push protection', 'Live ruleset protect-default-branch')
    }

    It 'fails when no ruleset has the name' {
        $script:responses[$script:rulesetList] = Get-FakeResult -Output '[{"id":7,"name":"tags"}]'
        $results = @(Test-LiveRuleset -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch' -IsPrivate $false)
        $results.Count | Should -Be 1
        $results[0].Status | Should -Be 'Fail'
        $results[0].Detail | Should -BeLike 'not found*'
    }

    It 'fails a ruleset that is not enforced (<Enforcement>)' -ForEach @(
        @{ Enforcement = 'evaluate' }
        @{ Enforcement = 'disabled' }
    ) {
        $script:responses["repos/$script:repo/rulesets/42"] = Get-FakeResult -Output (Get-LiveRulesetJson -Enforcement $Enforcement)
        $row = (Get-Row -Results @(Test-LiveRuleset -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch') `
                -Like '*enforcement')[0]
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -Be "is $Enforcement, policy wants active"
    }

    It 'fails a live ruleset whose required checks differ from the policy' {
        $script:responses["repos/$script:repo/rulesets/42"] = Get-FakeResult -Output (Get-LiveRulesetJson -Contexts 'lint', 'test')
        $row = (Get-Row -Results @(Test-LiveRuleset -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch') `
                -Like '*status checks')[0]
        $row.Status | Should -Be 'Fail'
        $row.Detail | Should -Be 'missing: workflow-lint, secret-scan, dependency-review, pr-policy'
    }

    It 'stops at one Fail row when the repository cannot be read' {
        $script:responses.Remove("repos/$script:repo")
        $results = @(Test-LiveRepository -Repository $script:repo -Policy $script:policy -RulesetName 'protect-default-branch')
        $results.Count | Should -Be 1
        $results[0].Check | Should -Be 'Live repository'
        $results[0].Status | Should -Be 'Fail'
        Should -Invoke Invoke-Cli -Times 1 -Exactly
    }

    It 'rejects a bad repository name before calling gh' {
        { Test-LiveRepository -Repository 'octo-org/demo/../x' -Policy $script:policy } | Should -Throw '*Repository must look like owner/name*'
        Should -Invoke Invoke-Cli -Times 0 -Exactly
    }
}

Describe 'Test-RepoGovernance.ps1 main block' {
    BeforeAll {
        $script:pwsh = (Get-Process -Id $PID).Path
    }

    It 'exits 0 and prints the table for a complete governed tree' {
        $root = Initialize-GovernedTree -Name 'main-pass'
        $output = & $script:pwsh -NoProfile -File $script:scriptPath -Path $root 2>&1
        $LASTEXITCODE | Should -Be 0
        "$output" | Should -BeLike '*Check*Status*Detail*Required file README.md*Pass*'
        "$output" | Should -BeLike '*All governance checks passed*'
    }

    It 'exits 1 when a check fails' {
        $root = Initialize-GovernedTree -Name 'main-fail'
        Remove-Item -LiteralPath (Join-Path -Path $root -ChildPath 'SECURITY.md')
        $output = & $script:pwsh -NoProfile -File $script:scriptPath -Path $root 2>&1
        $LASTEXITCODE | Should -Be 1
        "$output" | Should -BeLike '*Required file SECURITY.md*Fail*missing*'
        "$output" | Should -BeLike '*1 of * governance check(s) failed*'
    }

    It 'exits 1 with a message when the policy file is missing' {
        $output = & $script:pwsh -NoProfile -File $script:scriptPath -Path $TestDrive -PolicyPath (Join-Path -Path $TestDrive -ChildPath 'none.json') 2>&1
        $LASTEXITCODE | Should -Be 1
        "$output" | Should -BeLike '*Policy file not found*'
    }
}
