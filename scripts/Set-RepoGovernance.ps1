<#
.SYNOPSIS
    Applies governance/policy.json to a GitHub repository: merge settings, security features and the
    default-branch ruleset.

.DESCRIPTION
    Every change goes through the GitHub REST API with gh api, in this order:
      1. PATCH repos/{r} with policy.repoSettings (squash-only merges, delete merged branches, no wiki...).
      2. PUT repos/{r}/vulnerability-alerts and repos/{r}/automated-security-fixes (Dependabot), when enabled.
      3. PATCH repos/{r} with security_and_analysis: secret scanning and push protection, when enabled.
      4. PUT repos/{r}/private-vulnerability-reporting, when enabled.
      5. Creates or updates the ruleset in policy.rulesetPath, found by its name: PUT when a ruleset of
         that name exists, POST when it does not.
    Safe to run again: every call sets a state, so a second run changes nothing.
    Steps 3 to 5 depend on the plan. GitHub refuses them on a private repository without GitHub Pro,
    Team or Advanced Security (HTTP 403, 404 or 422); that is a warning, not a failure. Any other error
    stops the run. -WhatIf prints every change and makes none.
    Exits 0 on success (warnings included), 1 on failure.

.PARAMETER Repository
    The repository to govern, as owner/name.

.PARAMETER PolicyPath
    The policy file. Its rulesetPath is read relative to the folder above the policy's folder
    (the repository root for governance/policy.json).

.EXAMPLE
    pwsh ./scripts/Set-RepoGovernance.ps1 -Repository kaushik-sai/my-service -WhatIf

.EXAMPLE
    pwsh ./scripts/Set-RepoGovernance.ps1 -Repository kaushik-sai/my-service
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Repository,
    [ValidateNotNullOrEmpty()]
    [string] $PolicyPath = (Join-Path -Path $PSScriptRoot -ChildPath '..' -AdditionalChildPath 'governance', 'policy.json')
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

# The answers GitHub gives when a feature is not available on the repository's plan.
$script:PlanGatedStatus = @(403, 404, 422)

# True when a policy.securityFeatures flag is present and true. A missing flag means off.
function Test-PolicyFlag {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [object] $Features,
        [Parameter(Mandatory)] [string] $Name
    )
    $property = $Features.PSObject.Properties[$Name]
    [bool] ($property -and $property.Value)
}

# One gh api call. The body, when given, goes on stdin (--input -).
function Invoke-GitHubApi {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'PATCH', 'PUT', 'POST')] [string] $Method,
        [Parameter(Mandatory)] [string] $Endpoint,
        [string] $Body
    )
    $arguments = @('api', '--method', $Method, $Endpoint)
    if ($PSBoundParameters.ContainsKey('Body')) {
        Invoke-Cli -Name gh -Arguments ($arguments + @('--input', '-')) -InputText $Body
    } else {
        Invoke-Cli -Name gh -Arguments $arguments
    }
}

# What to tell the person when GitHub refuses a plan-dependent feature.
function Get-PlanGatedMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Feature,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [int] $Status,
        [AllowEmptyString()] [string] $Output
    )
    # gh ends its error output with "gh: <message> (HTTP <status>)"; keep just the message.
    $reason = @($Output -split '\r?\n' | Where-Object { $_.Trim() }) | Select-Object -Last 1
    $reason = "$reason" -replace '^gh:\s*', '' -replace '\s*\(HTTP \d{3}\)\s*$', ''
    "Skipped $Feature on ${Repository}: GitHub answered HTTP $Status ($reason). " +
    'On a private repository this feature needs GitHub Pro, Team or Advanced Security; ' +
    'make the repository public or upgrade the plan, then run this again. It also happens when your token lacks admin rights.'
}

# The first PATCH: the merge and feature settings from policy.repoSettings, as they are.
function Build-RepoSettingsPayload {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)] [object] $Policy)
    $payload = [ordered] @{}
    foreach ($property in $Policy.repoSettings.PSObject.Properties) {
        $payload[$property.Name] = $property.Value
    }
    $payload
}

# The second PATCH: secret scanning and push protection. $null when the policy enables neither.
# Kept apart from the first so a plan that refuses secret scanning does not block the merge settings.
function Build-SecurityAnalysisPayload {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)] [object] $Policy)
    $analysis = [ordered] @{}
    if (Test-PolicyFlag -Features $Policy.securityFeatures -Name 'secretScanning') {
        $analysis['secret_scanning'] = [ordered] @{ status = 'enabled' }
    }
    if (Test-PolicyFlag -Features $Policy.securityFeatures -Name 'secretScanningPushProtection') {
        $analysis['secret_scanning_push_protection'] = [ordered] @{ status = 'enabled' }
    }
    if ($analysis.Count -eq 0) {
        return $null
    }
    [ordered] @{ security_and_analysis = $analysis }
}

# The ruleset file named by policy.rulesetPath, as text. Throws when it is missing, is not JSON or has no name.
function Get-RulesetJson {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $PolicyPath,
        [Parameter(Mandatory)] [object] $Policy
    )
    $root = Split-Path -Path (Split-Path -Path $PolicyPath -Parent) -Parent
    $path = Join-Path -Path $root -ChildPath $Policy.rulesetPath
    if (-not (Test-Path -Path $path -PathType Leaf)) {
        throw "Ruleset file not found: $path"
    }
    $json = Get-Content -Path $path -Raw
    $ruleset = $json | ConvertFrom-Json
    if (-not $ruleset.PSObject.Properties['name'] -or -not $ruleset.name) {
        throw "Ruleset file has no name: $path"
    }
    $json
}

# One write call. Returns $true when GitHub accepted it and $false when nothing was sent (-WhatIf)
# or a plan-gated feature was refused (with a warning). Throws on any other failure.
function Invoke-GovernanceChange {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $Feature,
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [ValidateSet('PATCH', 'PUT', 'POST')] [string] $Method,
        [Parameter(Mandatory)] [string] $Endpoint,
        [string] $Body,
        [switch] $PlanGated
    )
    if (-not $PSCmdlet.ShouldProcess($Repository, "$Feature ($Method $Endpoint)")) {
        return $false
    }
    $call = @{ Method = $Method; Endpoint = $Endpoint }
    if ($PSBoundParameters.ContainsKey('Body')) {
        $call.Body = $Body
    }
    $result = Invoke-GitHubApi @call
    if ($result.ExitCode -eq 0) {
        Write-Information "Applied: $Feature"
        return $true
    }
    $status = Get-HttpStatus -Output $result.Output
    if ($PlanGated -and $status -in $script:PlanGatedStatus) {
        Write-Warning (Get-PlanGatedMessage -Feature $Feature -Repository $Repository -Status $status -Output $result.Output)
        return $false
    }
    throw "$Feature failed ($Method $Endpoint, exit $($result.ExitCode)): $($result.Output)"
}

# Creates the ruleset, or updates the one with the same name, so running twice never makes a copy.
function Set-RepositoryRuleset {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [string] $RulesetJson
    )
    $name = ($RulesetJson | ConvertFrom-Json).name
    $feature = "ruleset '$name'"
    # Reading is not a change, so it runs under -WhatIf too and the preview can say create or update.
    # includes_parents=false: organization rulesets cannot be changed through the repository.
    $list = Invoke-GitHubApi -Method GET -Endpoint "repos/$Repository/rulesets?includes_parents=false&per_page=100"
    if ($list.ExitCode -ne 0) {
        $status = Get-HttpStatus -Output $list.Output
        if ($status -in $script:PlanGatedStatus) {
            Write-Warning (Get-PlanGatedMessage -Feature $feature -Repository $Repository -Status $status -Output $list.Output)
            return
        }
        throw "Listing the rulesets of $Repository failed (exit $($list.ExitCode)): $($list.Output)"
    }
    $existing = @($list.Output | ConvertFrom-Json | Where-Object name -EQ $name)
    if ($existing.Count -gt 0) {
        $id = $existing[0].id
        $null = Invoke-GovernanceChange -Feature "$feature (update id $id)" -Repository $Repository -Method PUT `
            -Endpoint "repos/$Repository/rulesets/$id" -Body $RulesetJson -PlanGated
    } else {
        $null = Invoke-GovernanceChange -Feature "$feature (create)" -Repository $Repository -Method POST `
            -Endpoint "repos/$Repository/rulesets" -Body $RulesetJson -PlanGated
    }
}

# Applies the whole policy, in the order in the help above. Plan-gated refusals are warnings.
# Results are dropped with $null = rather than | Out-Null, which would hide the warnings from -WarningVariable.
function Invoke-RepoGovernance {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [Parameter(Mandatory)] [object] $Policy,
        [Parameter(Mandatory)] [string] $RulesetJson
    )
    Assert-RepositoryName -Repository $Repository
    $features = $Policy.securityFeatures

    $settings = Build-RepoSettingsPayload -Policy $Policy | ConvertTo-Json -Depth 10 -Compress
    $null = Invoke-GovernanceChange -Feature 'repository settings' -Repository $Repository -Method PATCH `
        -Endpoint "repos/$Repository" -Body $settings

    if (Test-PolicyFlag -Features $features -Name 'vulnerabilityAlerts') {
        $null = Invoke-GovernanceChange -Feature 'Dependabot vulnerability alerts' -Repository $Repository -Method PUT `
            -Endpoint "repos/$Repository/vulnerability-alerts"
    }
    if (Test-PolicyFlag -Features $features -Name 'automatedSecurityFixes') {
        $null = Invoke-GovernanceChange -Feature 'Dependabot security updates' -Repository $Repository -Method PUT `
            -Endpoint "repos/$Repository/automated-security-fixes"
    }

    $analysis = Build-SecurityAnalysisPayload -Policy $Policy
    if ($analysis) {
        $null = Invoke-GovernanceChange -Feature 'secret scanning and push protection' -Repository $Repository -Method PATCH `
            -Endpoint "repos/$Repository" -Body ($analysis | ConvertTo-Json -Depth 10 -Compress) -PlanGated
    }
    if (Test-PolicyFlag -Features $features -Name 'privateVulnerabilityReporting') {
        $null = Invoke-GovernanceChange -Feature 'private vulnerability reporting' -Repository $Repository -Method PUT `
            -Endpoint "repos/$Repository/private-vulnerability-reporting" -PlanGated
    }

    Set-RepositoryRuleset -Repository $Repository -RulesetJson $RulesetJson
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    $governanceWarnings = @()
    try {
        Assert-RepositoryName -Repository $Repository
        if (-not (Test-ToolInstalled -Name 'gh')) {
            throw 'gh is not on PATH. Install the GitHub CLI and run gh auth login.'
        }
        $policy = Get-GovernancePolicy -Path $PolicyPath
        $rulesetJson = Get-RulesetJson -PolicyPath $PolicyPath -Policy $policy
        Invoke-RepoGovernance -Repository $Repository -Policy $policy -RulesetJson $rulesetJson -WarningVariable governanceWarnings
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    if ($WhatIfPreference) {
        Write-Information "-WhatIf: nothing was changed on $Repository."
    } else {
        Write-Information "Governance applied to $Repository with $(@($governanceWarnings).Count) warning(s)."
    }
    exit 0
}
