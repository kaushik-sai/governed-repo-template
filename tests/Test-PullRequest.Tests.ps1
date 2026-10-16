BeforeAll {
    # Dot-source so we get the functions without running the main block.
    . (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-PullRequest.ps1')
    $script:scriptPath = Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'scripts', 'Test-PullRequest.ps1'
    $script:policy = Get-GovernancePolicy

    $script:goodBody = @'
## What changed
Added the thing.

## Why
Because.

## How it was verified
Ran the tests.

## Risk and rollback
Low; revert the commit.

## AI assistance
None.
'@

    function Get-Status {
        param([object[]] $Result, [string] $Check)
        ($Result | Where-Object Check -eq $Check).Status
    }
    function Invoke-Check {
        param([string] $Title = 'feat(scope): add x', [string] $Body = $script:goodBody, [int] $ChangedFiles = -1)
        @(Invoke-PullRequestCheck -Title $Title -Body $Body -ChangedFiles $ChangedFiles -Policy $script:policy)
    }
}

Describe 'Title' {
    It 'passes <_>' -ForEach @('feat(scope): add x', 'fix: a bug', 'chore!: break', 'docs(a.b/c-d): words') {
        Get-Status (Invoke-Check -Title $_) 'Title' | Should -Be 'Pass'
    }
    It 'fails <_>' -ForEach @(
        'add the thing',
        'feat add x',
        'Feat(scope): add x',
        'FEAT: add x',
        'feat: ',
        ' feat: add x',
        'feat:  leading space',
        'feat(Scope): bad scope',
        "feat: a`nsecond line",
        ''
    ) {
        Get-Status (Invoke-Check -Title $_) 'Title' | Should -Be 'Fail'
    }
    It 'fails a summary that is too long' {
        Get-Status (Invoke-Check -Title ('feat: ' + ('x' * 100))) 'Title' | Should -Be 'Fail'
    }
    It 'passes a summary at the limit' {
        Get-Status (Invoke-Check -Title ('feat: ' + ('x' * 99))) 'Title' | Should -Be 'Pass'
    }
    It 'treats injection-looking text as data' {
        $marker = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "pwned-$([guid]::NewGuid().ToString('N'))"
        New-Item -ItemType File -Path $marker | Out-Null
        $evil = "`$(Remove-Item -Path '$marker')"
        Get-Status (Invoke-Check -Title $evil -Body $evil) 'Title' | Should -Be 'Fail'
        Get-Status (Invoke-Check -Title "feat: x `$(Remove-Item -Path '$marker')" -Body $evil) 'Title' | Should -Be 'Pass'
        Test-Path -Path $marker | Should -BeTrue
        Remove-Item -Path $marker -Force
    }
}

Describe 'Sections' {
    It 'passes a complete body' {
        @(Invoke-Check | Where-Object Status -ne 'Pass').Count | Should -Be 0
    }
    It 'fails a missing section' {
        $body = $script:goodBody -replace '(?s)## Why\r?\nBecause\.\r?\n\r?\n', ''
        Get-Status (Invoke-Check -Body $body) '## Why' | Should -Be 'Fail'
    }
    It 'fails an empty section' {
        $body = $script:goodBody -replace 'Because\.', ''
        Get-Status (Invoke-Check -Body $body) '## Why' | Should -Be 'Fail'
    }
    It 'fails a section that only has an HTML comment' {
        $body = $script:goodBody -replace 'Because\.', "<!-- why?`nexplain -->"
        Get-Status (Invoke-Check -Body $body) '## Why' | Should -Be 'Fail'
    }
    It 'ignores a heading that is inside a comment' {
        $body = "<!--`n## Why`nBecause`n-->`n" + ($script:goodBody -replace '(?s)## Why\r?\nBecause\.\r?\n\r?\n', '')
        Get-Status (Invoke-Check -Body $body) '## Why' | Should -Be 'Fail'
    }
    It 'accepts content next to a comment' {
        $body = $script:goodBody -replace 'Because\.', "<!-- hint -->`nBecause."
        Get-Status (Invoke-Check -Body $body) '## Why' | Should -Be 'Pass'
    }
    It 'matches headings case-insensitively and with CRLF' {
        $body = ($script:goodBody -replace '## What changed', '## WHAT CHANGED') -replace "`n", "`r`n"
        @(Invoke-Check -Body $body | Where-Object Status -eq 'Fail').Count | Should -Be 0
    }
    It 'fails every section on an empty body' {
        $result = Invoke-Check -Body ''
        @($result | Where-Object { $_.Status -eq 'Fail' -and $_.Check -ne 'Title' }).Count | Should -Be 5
    }
    It 'fails a missing AI assistance section' {
        $body = $script:goodBody -replace '(?s)## AI assistance.*$', ''
        Get-Status (Invoke-Check -Body $body) '## AI assistance' | Should -Be 'Fail'
    }
}

Describe 'Changed files' {
    It 'passes at the limit' {
        Get-Status (Invoke-Check -ChangedFiles $script:policy.pullRequest.maxChangedFiles) 'Changed files' | Should -Be 'Pass'
    }
    It 'warns above the limit and never fails' {
        $result = Invoke-Check -ChangedFiles ($script:policy.pullRequest.maxChangedFiles + 1)
        Get-Status $result 'Changed files' | Should -Be 'Warn'
        @($result | Where-Object Status -eq 'Fail').Count | Should -Be 0
    }
    It 'is skipped when the count is not given' {
        @(Invoke-Check | Where-Object Check -eq 'Changed files').Count | Should -Be 0
    }
}

Describe 'TitleOnly (Dependabot pull requests)' {
    It 'checks the title, warns about the skipped body and never fails on the body' {
        $result = Invoke-PullRequestCheck -Title 'ci(deps): bump the actions group' -Body 'Bumps actions/checkout.' -Policy $script:policy -TitleOnly
        Get-Status $result 'Title' | Should -Be 'Pass'
        Get-Status $result 'Body' | Should -Be 'Warn'
        @($result | Where-Object Status -eq 'Fail').Count | Should -Be 0
    }
    It 'still fails a bad title' {
        $result = Invoke-PullRequestCheck -Title 'Bump actions' -Body '' -Policy $script:policy -TitleOnly
        Get-Status $result 'Title' | Should -Be 'Fail'
    }
}

Describe 'ConvertTo-SummaryMarkdown' {
    It 'writes a markdown table with one row per check' {
        $text = ConvertTo-SummaryMarkdown -Result (Invoke-Check)
        $text | Should -Match '\| Check \| Status \| Detail \|'
        $text | Should -Match '\| Title \| Pass \|'
    }
}

Describe 'Test-PullRequest.ps1 as a command' {
    BeforeEach {
        $script:summary = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath "summary-$([guid]::NewGuid().ToString('N')).md"
    }
    AfterEach { Remove-Item -Path $script:summary -Force -ErrorAction SilentlyContinue }

    It 'exits 0, writes the summary and no errors for a good pull request' {
        $env:GITHUB_STEP_SUMMARY = $script:summary
        try {
            $out = & pwsh -NoProfile -File $script:scriptPath -Title 'feat: x' -Body $script:goodBody -ChangedFiles 3 2>&1 | Out-String
        } finally { $env:GITHUB_STEP_SUMMARY = $null }
        $LASTEXITCODE | Should -Be 0
        $out | Should -Not -Match '::error'
        Get-Content -Path $script:summary -Raw | Should -Match '\| Title \| Pass \|'
    }
    It 'exits 1 and emits ::error:: for a bad title' {
        $env:GITHUB_STEP_SUMMARY = $script:summary
        try {
            $out = & pwsh -NoProfile -File $script:scriptPath -Title 'nope' -Body $script:goodBody 2>&1 | Out-String
        } finally { $env:GITHUB_STEP_SUMMARY = $null }
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match '::error title=Pull request policy::Title'
    }
    It 'exits 0 when only the file count warns' {
        $null = & pwsh -NoProfile -File $script:scriptPath -Title 'feat: x' -Body $script:goodBody -ChangedFiles 500 2>&1
        $LASTEXITCODE | Should -Be 0
    }
}
