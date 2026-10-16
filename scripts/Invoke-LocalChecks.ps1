<#
.SYNOPSIS
    Runs the same checks as CI, before you push.

.DESCRIPTION
    Checks, in order:
      lint        PSScriptAnalyzer on the whole repo; Error, Warning and ParseError findings fail
      test        Pester on ./tests
      actionlint  GitHub Actions workflow syntax
      zizmor      GitHub Actions security (offline, so no token is needed)
      gitleaks    secrets. In a git repository it runs `gitleaks git`, which scans every commit
                  that a push would publish, including a secret added and deleted again.
                  Outside one it runs `gitleaks dir .` on the files.
    A tool that is not installed is reported as Skip with how to install it. A check you
    pass in -Skip is reported as Skip too. Prints a summary table. Exits 1 if any check failed.

.PARAMETER Skip
    Checks to leave out: lint, test, actionlint, zizmor, gitleaks.

.EXAMPLE
    pwsh ./scripts/Invoke-LocalChecks.ps1 -Skip zizmor
#>
[CmdletBinding()]
param(
    [ValidateSet('lint', 'test', 'actionlint', 'zizmor', 'gitleaks')]
    [string[]] $Skip = @()
)

Set-StrictMode -Version Latest
. (Join-Path -Path $PSScriptRoot -ChildPath 'lib' -AdditionalChildPath 'Cli.ps1')

# The checks, in order: what each one needs and how to get it.
function Get-LocalCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param()
    [pscustomobject] @{ Name = 'lint'; Module = 'PSScriptAnalyzer'; Tool = $null; Install = 'Install-Module PSScriptAnalyzer -Scope CurrentUser' }
    [pscustomobject] @{ Name = 'test'; Module = 'Pester'; Tool = $null; Install = 'Install-Module Pester -Scope CurrentUser -MinimumVersion 5.5' }
    [pscustomobject] @{ Name = 'actionlint'; Module = $null; Tool = 'actionlint'; Install = 'winget install rhysd.actionlint (Windows) or brew install actionlint; https://github.com/rhysd/actionlint' }
    [pscustomobject] @{ Name = 'zizmor'; Module = $null; Tool = 'zizmor'; Install = 'pipx install zizmor or cargo install zizmor; https://docs.zizmor.sh/installation/' }
    [pscustomobject] @{ Name = 'gitleaks'; Module = $null; Tool = 'gitleaks'; Install = 'winget install gitleaks.gitleaks (Windows) or brew install gitleaks; https://github.com/gitleaks/gitleaks' }
}

function Test-ModuleInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Name)
    [bool] (Get-Module -ListAvailable -Name $Name)
}

# The one place that runs the tools. Tests mock this function.
# Returns the exit code and the combined stdout and stderr.
function Invoke-LocalTool {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)] [ValidateSet('lint', 'test', 'actionlint', 'zizmor', 'gitleaks')] [string] $Name)
    $pwsh = Join-Path -Path $PSHOME -ChildPath 'pwsh'
    $inGit = Test-Path -Path (Join-Path -Path (Get-Location) -ChildPath '.git')
    $lint = @'
$r = @(Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1)
$r | Format-Table Severity, RuleName, ScriptName, Line, Message -AutoSize -Wrap | Out-String -Width 200
$b = @($r | Where-Object Severity -In 'Error', 'Warning', 'ParseError')
if ($b.Count -gt 0) { Write-Output "$($b.Count) error/warning finding(s)"; exit 1 }
'@
    $test = @'
$c = New-PesterConfiguration
$c.Run.Path = './tests'
$c.Run.Exit = $true
$c.Output.Verbosity = 'Normal'
Invoke-Pester -Configuration $c
'@
    $command = switch ($Name) {
        'lint' { @{ File = $pwsh; Arguments = @('-NoProfile', '-Command', $lint) } }
        'test' { @{ File = $pwsh; Arguments = @('-NoProfile', '-Command', $test) } }
        'actionlint' { @{ File = 'actionlint'; Arguments = @() } }
        'zizmor' { @{ File = 'zizmor'; Arguments = @('--offline', '.github/workflows') } }
        'gitleaks' {
            @{ File = 'gitleaks'; Arguments = @($(if ($inGit) { 'git' } else { 'dir' }), '.', '--redact', '--no-banner') }
        }
    }
    $file = $command.File
    $arguments = $command.Arguments
    $lines = @(& $file @arguments 2>&1 | ForEach-Object { "$_" })
    [pscustomobject] @{ ExitCode = $LASTEXITCODE; Output = ($lines -join [Environment]::NewLine) }
}

# Runs each check once. Returns one result per check: Check, Status (Pass, Fail, Skip), Detail.
function Invoke-LocalCheck {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([string[]] $Skip = @())
    foreach ($check in Get-LocalCheck) {
        $status = 'Pass'
        $detail = ''
        if ($check.Name -in $Skip) {
            $status = 'Skip'
            $detail = 'Skipped by -Skip.'
        } elseif ($check.Module -and -not (Test-ModuleInstalled -Name $check.Module)) {
            $status = 'Skip'
            $detail = "$($check.Module) is not installed. Install: $($check.Install)"
        } elseif ($check.Tool -and -not (Test-ToolInstalled -Name $check.Tool)) {
            $status = 'Skip'
            $detail = "$($check.Tool) is not installed. Install: $($check.Install)"
        } else {
            $run = Invoke-LocalTool -Name $check.Name
            if ($run.ExitCode -ne 0) {
                $status = 'Fail'
                $detail = "Exit code $($run.ExitCode).`n$($run.Output)"
            }
        }
        [pscustomobject] @{ Check = $check.Name; Status = $status; Detail = $detail }
    }
}

# Main: only runs when the script is executed, not when tests dot-source it.
if ($MyInvocation.InvocationName -ne '.') {
    $ErrorActionPreference = 'Stop'
    $InformationPreference = 'Continue'
    Push-Location -Path (Join-Path -Path $PSScriptRoot -ChildPath '..')
    try {
        $results = @(Invoke-LocalCheck -Skip $Skip)
    } finally {
        Pop-Location
    }
    foreach ($r in @($results | Where-Object Status -eq 'Fail')) {
        Write-Information "--- $($r.Check) ---`n$($r.Detail)"
    }
    $table = $results | Select-Object Check, Status, @{ Name = 'Detail'; Expression = { ($_.Detail -split "`n")[0] } }
    Write-Information ($table | Format-Table -AutoSize -Wrap | Out-String -Width 200)
    $failed = @($results | Where-Object Status -eq 'Fail')
    if ($failed.Count -gt 0) {
        Write-Error "$($failed.Count) of $($results.Count) local check(s) failed." -ErrorAction Continue
        exit 1
    }
    Write-Information "No check failed ($(@($results | Where-Object Status -eq 'Skip').Count) skipped)."
    exit 0
}
