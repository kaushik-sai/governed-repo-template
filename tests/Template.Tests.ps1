# Policy as code for the template itself: the workflows are pinned and least-privilege, and
# governance/policy.json, the ruleset and the workflows agree with each other. No network.

BeforeDiscovery {
    $root = Split-Path -Path $PSScriptRoot -Parent
    $script:workflowFiles = @(Get-ChildItem -Path (Join-Path -Path $root -ChildPath '.github/workflows') -Filter '*.yml' -File |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } })
    $policy = Get-Content -Path (Join-Path -Path $root -ChildPath 'governance/policy.json') -Raw | ConvertFrom-Json
    $script:requiredFiles = @($policy.requiredFiles | ForEach-Object { @{ File = $_ } })
    $script:requiredChecks = @($policy.requiredStatusChecks | ForEach-Object { @{ Check = $_ } })
}

BeforeAll {
    $script:Root = Split-Path -Path $PSScriptRoot -Parent
    $script:Policy = Get-Content -Path (Join-Path -Path $script:Root -ChildPath 'governance/policy.json') -Raw | ConvertFrom-Json

    # Lines of a file with comment-only lines blanked, so a comment never counts as configuration.
    function Get-CodeLine {
        param([string] $Path)
        @(Get-Content -Path $Path | ForEach-Object { if ($_ -match '^\s*#') { '' } else { $_ } })
    }

    function Get-Indent {
        param([string] $Line)
        $Line.Length - $Line.TrimStart().Length
    }

    # The lines nested under the line at $Start: everything after it that is indented deeper than $Indent.
    function Get-Block {
        param([string[]] $Lines, [int] $Start, [int] $Indent)
        $block = @()
        for ($i = $Start + 1; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i].Trim() -eq '') { $block += $Lines[$i]; continue }
            if ((Get-Indent -Line $Lines[$i]) -le $Indent) { break }
            $block += $Lines[$i]
        }
        , $block
    }

    # The jobs of a workflow: id, and the lines of the job.
    function Get-WorkflowJob {
        param([string[]] $Lines)
        $start = [array]::FindIndex($Lines, [Predicate[string]] { param($l) $l -match '^jobs:\s*$' })
        if ($start -lt 0) { return }
        $body = Get-Block -Lines $Lines -Start $start -Indent 0
        for ($i = 0; $i -lt $body.Count; $i++) {
            if ($body[$i] -match '^  ([A-Za-z0-9_-]+):\s*$') {
                [pscustomobject]@{ Id = $Matches[1]; Lines = (Get-Block -Lines $body -Start $i -Indent 2) }
            }
        }
    }

    # The text of every run: step, one string per step (block scalar or single line).
    function Get-RunText {
        param([string[]] $Lines)
        for ($i = 0; $i -lt $Lines.Count; $i++) {
            if ($Lines[$i] -match '^(\s*)(?:-\s+)?run:\s*(.*)$') {
                $inline = $Matches[2]
                if ($inline -match '^[|>][+-]?\s*$') {
                    # The key sits at the column of "run:", after any "- ".
                    $keyIndent = $Lines[$i].IndexOf('run:')
                    (Get-Block -Lines $Lines -Start $i -Indent ($keyIndent - 1)) -join "`n"
                }
                else { $inline }
            }
        }
    }
}

Describe 'Workflow <Name>' -ForEach $script:workflowFiles {
    BeforeAll {
        $script:Lines = Get-CodeLine -Path $Path
        $script:Text = $script:Lines -join "`n"
    }

    It 'pins every action to a full commit SHA with a version comment' {
        $raw = Get-Content -Path $Path
        $bad = @()
        foreach ($line in $raw) {
            if ($line -match '^\s*(?:-\s+)?uses:\s*(\S+)(.*)$') {
                $ref = $Matches[1]
                $rest = $Matches[2]
                if ($ref.StartsWith('./')) { continue }
                if ($ref -notmatch '@[0-9a-f]{40}$' -or $rest -notmatch '#\s*v\d') { $bad += $line.Trim() }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'sets top-level permissions' {
        $script:Text | Should -Match '(?m)^permissions:'
    }

    It 'never grants write-all or contents: write' {
        $script:Text | Should -Not -Match 'write-all'
        $script:Text | Should -Not -Match '(?m)^\s*contents:\s*write'
    }

    It 'does not use pull_request_target' {
        $script:Text | Should -Not -Match 'pull_request_target'
    }

    It 'sets persist-credentials: false on every checkout' {
        $bad = @()
        for ($i = 0; $i -lt $script:Lines.Count; $i++) {
            if ($script:Lines[$i] -match '^(\s*)(?:-\s+)?uses:\s*actions/checkout@') {
                $step = $script:Lines[$i].IndexOf('uses:')
                $block = Get-Block -Lines $script:Lines -Start $i -Indent ($step - 1)
                if (($block -join "`n") -notmatch '(?m)^\s*persist-credentials:\s*false\s*$') { $bad += "line $($i + 1)" }
            }
        }
        $bad | Should -BeNullOrEmpty
    }

    It 'sets timeout-minutes on every job' {
        $jobs = @(Get-WorkflowJob -Lines $script:Lines)
        $jobs.Count | Should -BeGreaterThan 0
        $missing = @($jobs | Where-Object { ($_.Lines -join "`n") -notmatch '(?m)^    timeout-minutes:\s*\d+\s*$' } | ForEach-Object Id)
        $missing | Should -BeNullOrEmpty
    }

    It 'keeps PR title, body and head ref out of run: scripts' {
        $runs = @(Get-RunText -Lines $script:Lines)
        $bad = @($runs | Where-Object { $_ -match 'github\.event\.pull_request\.(title|body)|github\.head_ref' })
        $bad | Should -BeNullOrEmpty
    }
}

Describe 'Required files' {
    It '<File> exists' -ForEach $script:requiredFiles {
        Join-Path -Path $script:Root -ChildPath $File | Should -Exist
    }
}

Describe 'Required status checks' {
    BeforeAll {
        $script:JobIds = @()
        $script:JobNames = @{}
        foreach ($file in Get-ChildItem -Path (Join-Path -Path $script:Root -ChildPath '.github/workflows') -Filter '*.yml' -File) {
            foreach ($job in Get-WorkflowJob -Lines (Get-CodeLine -Path $file.FullName)) {
                $script:JobIds += $job.Id
                $name = $job.Lines | Where-Object { $_ -match '^    name:\s*(.+?)\s*$' } | Select-Object -First 1
                $script:JobNames[$job.Id] = if ($name) { ($name -replace '^\s*name:\s*', '').Trim("'", '"') } else { $job.Id }
            }
        }
    }

    It 'the ruleset requires exactly the checks in policy.json' {
        $rulesetPath = Join-Path -Path $script:Root -ChildPath $script:Policy.rulesetPath
        $ruleset = Get-Content -Path $rulesetPath -Raw | ConvertFrom-Json
        $rule = $ruleset.rules | Where-Object type -EQ 'required_status_checks'
        $contexts = @($rule.parameters.required_status_checks | ForEach-Object context)
        $contexts | Sort-Object | Should -Be ($script:Policy.requiredStatusChecks | Sort-Object)
    }

    It '<Check> is a job id in a workflow' -ForEach $script:requiredChecks {
        $script:JobIds | Should -Contain $Check
    }

    It '<Check> has a name: equal to its job id' -ForEach $script:requiredChecks {
        # The status check is reported under the job name, so the two must match.
        $script:JobNames[$Check] | Should -Be $Check
    }
}
