<#
.SYNOPSIS
    Creates a new GitHub repository from this template and governs it straight away.

.DESCRIPTION
    1. Stops if the repository already exists (gh repo view succeeds), so it never touches existing work.
    2. Creates it with gh repo create <name> --template <template> --<visibility>.
    3. Runs scripts/Set-RepoGovernance.ps1 for it: merge settings, security features and the ruleset.
    4. Prints the next steps: clone it and put your own owner in .github/CODEOWNERS.
    -WhatIf prints what would be created and governed, and changes nothing.
    Exits 0 on success, 1 on failure.

.PARAMETER Name
    The new repository, as owner/name.

.PARAMETER Template
    The template repository, as owner/name.

.PARAMETER Visibility
    private (default), public or internal.

.PARAMETER Description
    Optional one-line description of the new repository.

.EXAMPLE
    pwsh ./scripts/New-GovernedRepo.ps1 -Name kaushik-sai/my-service -Description 'Orders API'

.EXAMPLE
    pwsh ./scripts/New-GovernedRepo.ps1 -Name kaushik-sai/my-service -Visibility public -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string] $Name,
    [ValidateNotNullOrEmpty()]
    [string] $Template = 'kaushik-sai/governed-repo-template',
    [ValidateSet('private', 'public', 'internal')]
    [string] $Visibility = 'private',
    [string] $Description
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

# True when gh can see the repository. Any failure (not found, no access) counts as absent.
function Test-RepositoryExist {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Repository)
    (Invoke-Cli -Name gh -Arguments @('repo', 'view', $Repository, '--json', 'name')).ExitCode -eq 0
}

# The gh repo create arguments, as data.
function Get-RepoCreateArgument {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [ValidateSet('private', 'public', 'internal')] [string] $Visibility,
        [string] $Description
    )
    $describe = if ($Description) { @('--description', $Description) } else { @() }
    [string[]] (@('repo', 'create', $Name, '--template', $Template, "--$Visibility") + $describe)
}

function New-RepositoryFromTemplate {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [string] $Visibility,
        [string] $Description
    )
    if (-not $PSCmdlet.ShouldProcess($Name, "Create $Visibility repository from template $Template")) {
        return
    }
    $arguments = Get-RepoCreateArgument -Name $Name -Template $Template -Visibility $Visibility -Description $Description
    $result = Invoke-Cli -Name gh -Arguments $arguments
    if ($result.ExitCode -ne 0) {
        throw "gh repo create $Name failed (exit $($result.ExitCode)): $($result.Output)"
    }
    Write-Information "Created $Name from $Template."
}

# Runs Set-RepoGovernance.ps1 in its own scope and returns its exit code.
# A function so tests can mock it; -ScriptPath lets them run a stand-in script instead.
function Invoke-SetRepoGovernance {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)] [string] $Repository,
        [string] $ScriptPath = (Join-Path -Path $PSScriptRoot -ChildPath 'Set-RepoGovernance.ps1')
    )
    if (-not $PSCmdlet.ShouldProcess($Repository, "Apply governance with $ScriptPath")) {
        return 0
    }
    & $ScriptPath -Repository $Repository | Out-Host
    $LASTEXITCODE
}

# What the person does next, once the repository is created and governed.
function Get-NextStep {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Repository)
    $folder = ($Repository -split '/')[1]
    @(
        ''
        'Next steps:'
        "  1. gh repo clone $Repository; cd $folder"
        '  2. Edit .github/CODEOWNERS: replace the template owner with your GitHub user or team, then commit it on a branch and open a pull request.'
        "  3. pwsh ./scripts/Test-RepoGovernance.ps1 -Path . -Repository $Repository"
    ) -join [Environment]::NewLine
}

# Creates and governs the repository. Throws on any failure; the message says what is left to do.
function Invoke-NewGovernedRepo {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $Template,
        [Parameter(Mandatory)] [string] $Visibility,
        [string] $Description
    )
    Assert-RepositoryName -Repository $Name
    Assert-RepositoryName -Repository $Template
    if (Test-RepositoryExist -Repository $Name) {
        throw "$Name already exists. Choose another name, or run scripts/Set-RepoGovernance.ps1 -Repository $Name to govern it."
    }
    New-RepositoryFromTemplate -Name $Name -Template $Template -Visibility $Visibility -Description $Description
    $exitCode = Invoke-SetRepoGovernance -Repository $Name
    if ($exitCode -ne 0) {
        throw "$Name was created, but governance failed (exit $exitCode). Fix the error above and run scripts/Set-RepoGovernance.ps1 -Repository $Name."
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    try {
        if (-not (Test-ToolInstalled -Name 'gh')) {
            throw 'gh is not on PATH. Install the GitHub CLI and run gh auth login.'
        }
        Invoke-NewGovernedRepo -Name $Name -Template $Template -Visibility $Visibility -Description $Description
    } catch {
        Write-Error $_.Exception.Message -ErrorAction Continue
        exit 1
    }
    if ($WhatIfPreference) {
        Write-Information "-WhatIf: nothing was created."
    } else {
        Write-Information (Get-NextStep -Repository $Name)
    }
    exit 0
}
