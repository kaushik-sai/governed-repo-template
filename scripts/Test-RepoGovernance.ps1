<#
.SYNOPSIS
    Checks a repository against governance/policy.json, in the working tree and, with -Repository, on GitHub.

.DESCRIPTION
    Offline checks, always run against the folder at -Path:
      - every file in policy.requiredFiles exists;
      - the ruleset file's required status checks are exactly policy.requiredStatusChecks;
      - every required status check is a job id in .github/workflows/*.yml, so the check can ever report.
    Online checks, only with -Repository (read-only gh api calls):
      - every policy.repoSettings value matches the live repository;
      - secret scanning and push protection are enabled, when the policy enables them;
      - Dependabot vulnerability alerts are enabled (HTTP 204 enabled, 404 disabled);
      - the ruleset is there by name, its enforcement is active and it requires the same checks.
    A feature the plan does not offer on a private repository (rulesets, secret scanning) is Warn, not Fail.
    Prints one row per check (Check, Status, Detail) as a table. Exits 1 if any check is Fail.

.PARAMETER Path
    Root of the working tree to check.

.PARAMETER Repository
    owner/name of the GitHub repository to check as well. Without it the online checks are skipped.

.PARAMETER PolicyPath
    The policy file. Defaults to governance/policy.json under -Path.

.EXAMPLE
    pwsh ./scripts/Test-RepoGovernance.ps1

.EXAMPLE
    pwsh ./scripts/Test-RepoGovernance.ps1 -Path . -Repository kaushik-sai/my-service
#>
[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [string] $Path = '.',
    [string] $Repository,
    [string] $PolicyPath
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

# The answers GitHub gives when a feature is not available on the repository's plan.
$script:PlanGatedStatus = @(403, 404, 422)

# One row of the report.
function ConvertTo-CheckResult {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Check,
        [Parameter(Mandatory)] [ValidateSet('Pass', 'Fail', 'Warn', 'Skip')] [string] $Status,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Detail
    )
    [pscustomobject] @{ Check = $Check; Status = $Status; Detail = $Detail }
}

# Value of a property, or $null when the object or the property is missing (StrictMode-safe).
function Get-PropertyValue {
    [CmdletBinding()]
    param(
        [AllowNull()] [object] $InputObject,
        [Parameter(Mandatory)] [string] $Name
    )
    if ($null -eq $InputObject) { return $null }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

# The contexts of every required_status_checks rule in a ruleset.
function Get-RulesetContext {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [object] $Ruleset)
    foreach ($rule in @(Get-PropertyValue -InputObject $Ruleset -Name 'rules')) {
        if ((Get-PropertyValue -InputObject $rule -Name 'type') -ne 'required_status_checks') { continue }
        $parameters = Get-PropertyValue -InputObject $rule -Name 'parameters'
        foreach ($check in @(Get-PropertyValue -InputObject $parameters -Name 'required_status_checks')) {
            $context = Get-PropertyValue -InputObject $check -Name 'context'
            if ($context) { [string] $context }
        }
    }
}

# Compares two sets of names. Returns nothing when they are equal, otherwise what is missing and extra.
function Compare-NameSet {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Expected,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Actual
    )
    $missing = @($Expected | Where-Object { $_ -cnotin $Actual } | Select-Object -Unique)
    $extra = @($Actual | Where-Object { $_ -cnotin $Expected } | Select-Object -Unique)
    $parts = @()
    if ($missing.Count -gt 0) { $parts += "missing: $($missing -join ', ')" }
    if ($extra.Count -gt 0) { $parts += "not in policy: $($extra -join ', ')" }
    if ($parts.Count -gt 0) { $parts -join '; ' }
}

# Job ids in one workflow file: the keys one indentation level under the top-level `jobs:` key.
# A line-based parse, enough for the plain YAML GitHub workflows use; no YAML module needed.
function Get-WorkflowJobId {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Content)
    $inJobs = $false
    $indent = $null
    foreach ($line in $Content -split '\r?\n') {
        if ($line -match '^\s*(#.*)?$') { continue }
        if ($line -match '^\S') {
            # A top-level key: either jobs: starts, or the jobs block has ended.
            $inJobs = $line -match '^["'']?jobs["'']?\s*:\s*(#.*)?$'
            $indent = $null
            continue
        }
        if (-not $inJobs) { continue }
        $leading = ($line -replace '^(\s*).*$', '$1').Length
        if ($null -eq $indent) { $indent = $leading }
        if ($leading -eq $indent -and $line -match '^\s*["'']?([A-Za-z_][A-Za-z0-9_-]*)["'']?\s*:') {
            $Matches[1]
        }
    }
}

function Test-RequiredFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Policy
    )
    foreach ($file in @($Policy.requiredFiles)) {
        $exists = Test-Path -LiteralPath (Join-Path -Path $Path -ChildPath $file) -PathType Leaf
        ConvertTo-CheckResult -Check "Required file $file" -Status $(if ($exists) { 'Pass' } else { 'Fail' }) `
            -Detail $(if ($exists) { 'present' } else { 'missing' })
    }
}

# The ruleset file must require exactly the checks the policy lists.
function Test-RulesetFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Policy
    )
    $check = 'Ruleset file status checks'
    $file = Join-Path -Path $Path -ChildPath $Policy.rulesetPath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        return ConvertTo-CheckResult -Check $check -Status Fail -Detail "$($Policy.rulesetPath) is missing"
    }
    try {
        $ruleset = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    } catch {
        return ConvertTo-CheckResult -Check $check -Status Fail -Detail "$($Policy.rulesetPath) is not valid JSON: $($_.Exception.Message)"
    }
    $difference = Compare-NameSet -Expected @($Policy.requiredStatusChecks) -Actual @(Get-RulesetContext -Ruleset $ruleset)
    if ($difference) {
        ConvertTo-CheckResult -Check $check -Status Fail -Detail $difference
    } else {
        ConvertTo-CheckResult -Check $check -Status Pass -Detail "same $(@($Policy.requiredStatusChecks).Count) checks as the policy"
    }
}

# A required check with no job of that name never reports, so every pull request would wait forever.
function Test-WorkflowJob {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Policy
    )
    $folder = Join-Path -Path $Path -ChildPath '.github' -AdditionalChildPath 'workflows'
    $jobs = @{}
    if (Test-Path -LiteralPath $folder -PathType Container) {
        foreach ($file in Get-ChildItem -LiteralPath $folder -File | Where-Object Extension -In '.yml', '.yaml') {
            foreach ($id in Get-WorkflowJobId -Content (Get-Content -LiteralPath $file.FullName -Raw)) {
                $jobs[$id] = $file.Name
            }
        }
    }
    foreach ($name in @($Policy.requiredStatusChecks)) {
        if ($jobs.ContainsKey($name)) {
            ConvertTo-CheckResult -Check "Workflow job $name" -Status Pass -Detail "job in $($jobs[$name])"
        } else {
            ConvertTo-CheckResult -Check "Workflow job $name" -Status Fail -Detail 'no job with this id in .github/workflows'
        }
    }
}

# Live settings (from gh api repos/{r}) and secret scanning against the policy.
# A setting GitHub does not return is Warn: some are only shown to admins.
function Test-LiveSetting {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [object] $Repo,
        [Parameter(Mandatory)] [object] $Policy
    )
    foreach ($property in $Policy.repoSettings.PSObject.Properties) {
        $check = "Live setting $($property.Name)"
        $live = $Repo.PSObject.Properties[$property.Name]
        if (-not $live) {
            ConvertTo-CheckResult -Check $check -Status Warn -Detail 'not returned by GitHub (needs admin access to read)'
        } elseif ("$($live.Value)" -eq "$($property.Value)") {
            ConvertTo-CheckResult -Check $check -Status Pass -Detail "$($live.Value)"
        } else {
            ConvertTo-CheckResult -Check $check -Status Fail -Detail "is $($live.Value), policy wants $($property.Value)"
        }
    }
    $isPrivate = [bool] (Get-PropertyValue -InputObject $Repo -Name 'private')
    $analysis = Get-PropertyValue -InputObject $Repo -Name 'security_and_analysis'
    $features = @(
        @{ Flag = 'secretScanning'; Key = 'secret_scanning'; Check = 'Live secret scanning' }
        @{ Flag = 'secretScanningPushProtection'; Key = 'secret_scanning_push_protection'; Check = 'Live push protection' }
    )
    foreach ($feature in $features) {
        if (-not (Get-PropertyValue -InputObject $Policy.securityFeatures -Name $feature.Flag)) { continue }
        $status = Get-PropertyValue -InputObject (Get-PropertyValue -InputObject $analysis -Name $feature.Key) -Name 'status'
        if ($status -eq 'enabled') {
            ConvertTo-CheckResult -Check $feature.Check -Status Pass -Detail 'enabled'
        } elseif ($isPrivate) {
            ConvertTo-CheckResult -Check $feature.Check -Status Warn `
                -Detail "is $(if ($status) { $status } else { 'not available' }) on this private repository (needs GitHub Advanced Security)"
        } else {
            ConvertTo-CheckResult -Check $feature.Check -Status Fail -Detail "is $(if ($status) { $status } else { 'not reported' }), policy wants enabled"
        }
    }
}

# Dependabot alerts: GitHub answers 204 when enabled and 404 when disabled.
function Test-LiveVulnerabilityAlert {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [object] $Policy
    )
    $check = 'Live vulnerability alerts'
    if (-not (Get-PropertyValue -InputObject $Policy.securityFeatures -Name 'vulnerabilityAlerts')) {
        return ConvertTo-CheckResult -Check $check -Status Skip -Detail 'not required by the policy'
    }
    $result = Invoke-Cli -Name gh -Arguments @('api', "repos/$Repository/vulnerability-alerts")
    if ($result.ExitCode -eq 0) {
        ConvertTo-CheckResult -Check $check -Status Pass -Detail 'enabled'
    } elseif ((Get-HttpStatus -Output $result.Output) -eq 404) {
        ConvertTo-CheckResult -Check $check -Status Fail -Detail 'disabled; run scripts/Set-RepoGovernance.ps1'
    } else {
        ConvertTo-CheckResult -Check $check -Status Fail -Detail "could not read: $($result.Output)"
    }
}

# The live ruleset, found by name: present, enforcement active and the same required checks.
function Test-LiveRuleset {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [object] $Policy,
        [Parameter(Mandatory)] [string] $RulesetName,
        [bool] $IsPrivate
    )
    $check = "Live ruleset $RulesetName"
    $list = Invoke-Cli -Name gh -Arguments @('api', "repos/$Repository/rulesets?includes_parents=false&per_page=100")
    if ($list.ExitCode -ne 0) {
        $status = Get-HttpStatus -Output $list.Output
        if ($IsPrivate -and $status -in $script:PlanGatedStatus) {
            return ConvertTo-CheckResult -Check $check -Status Warn `
                -Detail "rulesets are not available on this private repository's plan (HTTP $status); needs GitHub Pro or Team, or a public repository"
        }
        return ConvertTo-CheckResult -Check $check -Status Fail -Detail "could not list rulesets: $($list.Output)"
    }
    $match = @($list.Output | ConvertFrom-Json | Where-Object name -EQ $RulesetName)
    if ($match.Count -eq 0) {
        return ConvertTo-CheckResult -Check $check -Status Fail -Detail 'not found; run scripts/Set-RepoGovernance.ps1'
    }
    $detail = Invoke-Cli -Name gh -Arguments @('api', "repos/$Repository/rulesets/$($match[0].id)")
    if ($detail.ExitCode -ne 0) {
        return ConvertTo-CheckResult -Check $check -Status Fail -Detail "could not read ruleset $($match[0].id): $($detail.Output)"
    }
    $ruleset = $detail.Output | ConvertFrom-Json
    ConvertTo-CheckResult -Check $check -Status Pass -Detail "present (id $($match[0].id))"
    $enforcement = Get-PropertyValue -InputObject $ruleset -Name 'enforcement'
    ConvertTo-CheckResult -Check "$check enforcement" -Status $(if ($enforcement -eq 'active') { 'Pass' } else { 'Fail' }) `
        -Detail $(if ($enforcement -eq 'active') { 'active' } else { "is $enforcement, policy wants active" })
    $difference = Compare-NameSet -Expected @($Policy.requiredStatusChecks) -Actual @(Get-RulesetContext -Ruleset $ruleset)
    ConvertTo-CheckResult -Check "$check status checks" -Status $(if ($difference) { 'Fail' } else { 'Pass' }) `
        -Detail $(if ($difference) { $difference } else { 'same checks as the policy' })
}

# Every online check. A repository GitHub will not return stops the rest.
function Test-LiveRepository {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [object] $Policy,
        [string] $RulesetName
    )
    Assert-RepositoryName -Repository $Repository
    $result = Invoke-Cli -Name gh -Arguments @('api', "repos/$Repository")
    if ($result.ExitCode -ne 0) {
        return ConvertTo-CheckResult -Check 'Live repository' -Status Fail -Detail "could not read ${Repository}: $($result.Output)"
    }
    $repo = $result.Output | ConvertFrom-Json
    Test-LiveSetting -Repo $repo -Policy $Policy
    Test-LiveVulnerabilityAlert -Repository $Repository -Policy $Policy
    if ($RulesetName) {
        Test-LiveRuleset -Repository $Repository -Policy $Policy -RulesetName $RulesetName `
            -IsPrivate ([bool] (Get-PropertyValue -InputObject $repo -Name 'private'))
    } else {
        ConvertTo-CheckResult -Check 'Live ruleset' -Status Skip -Detail 'no readable ruleset file to compare with'
    }
}

# The name in the local ruleset file, or $null when the file is missing or not JSON.
function Get-RulesetName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Policy
    )
    $file = Join-Path -Path $Path -ChildPath $Policy.rulesetPath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    try {
        Get-PropertyValue -InputObject (Get-Content -LiteralPath $file -Raw | ConvertFrom-Json) -Name 'name'
    } catch {
        $null
    }
}

# Every check: offline always, online with -Repository.
function Invoke-GovernanceCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object] $Policy,
        [string] $Repository
    )
    Test-RequiredFile -Path $Path -Policy $Policy
    Test-RulesetFile -Path $Path -Policy $Policy
    Test-WorkflowJob -Path $Path -Policy $Policy
    if ($Repository) {
        Test-LiveRepository -Repository $Repository -Policy $Policy -RulesetName (Get-RulesetName -Path $Path -Policy $Policy)
    } else {
        ConvertTo-CheckResult -Check 'Live repository' -Status Skip -Detail 'no -Repository given; offline checks only'
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    try {
        if (-not $PolicyPath) {
            $PolicyPath = Join-Path -Path $Path -ChildPath 'governance' -AdditionalChildPath 'policy.json'
        }
        if ($Repository -and -not (Test-ToolInstalled -Name 'gh')) {
            throw 'gh is not on PATH; it is needed for -Repository. Install the GitHub CLI and run gh auth login.'
        }
        $policy = Get-GovernancePolicy -Path $PolicyPath
        $results = @(Invoke-GovernanceCheck -Path $Path -Policy $policy -Repository $Repository)
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    # A fixed width: without a terminal (CI, redirected output) the host reports none and the table would be empty.
    Write-Information ($results | Format-Table Check, Status, Detail -AutoSize -Wrap | Out-String -Width 200).TrimEnd()
    $failed = @($results | Where-Object Status -EQ 'Fail')
    $warned = @($results | Where-Object Status -EQ 'Warn')
    if ($failed.Count -gt 0) {
        Write-Error "$($failed.Count) of $($results.Count) governance check(s) failed ($($warned.Count) warning(s))." -ErrorAction Continue
        exit 1
    }
    Write-Information "All governance checks passed ($($warned.Count) warning(s))."
    exit 0
}
