# Evidence

Real runs that show the template working, and what is not verified yet. CI repeats the checks on every pull request and every push to `main`: [ci runs](https://github.com/kaushik-sai/governed-repo-template/actions/workflows/ci.yml), [security runs](https://github.com/kaushik-sai/governed-repo-template/actions/workflows/security.yml), [pr-policy runs](https://github.com/kaushik-sai/governed-repo-template/actions/workflows/pr-policy.yml).

## 1. Local checks on the build machine (2026-10-16)

Linux cloud session, PowerShell 7.6.7. Every tool was downloaded from its official release and checked against the SHA-256 the release publishes (PowerShell `hashes.sha256`, actionlint and gitleaks `checksums.txt`); zizmor 1.31.1 from PyPI. Pester 5.9.1 came from nuget.org and PSScriptAnalyzer 1.25.0 from its GitHub release, because the PowerShell Gallery was not reachable from the session.

`pwsh ./scripts/Invoke-LocalChecks.ps1`: **all 5 checks passed, 0 skipped, 25 s.**

| Check | Command | Result |
|---|---|---|
| lint | `Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1` | 0 findings at any severity, 16 PowerShell files |
| test | `Invoke-Pester -Path ./tests` | **339 passed, 0 failed, 0 skipped**, 8 test files, 15.2 s |
| actionlint | `actionlint` (1.7.12) | no findings |
| zizmor | `zizmor --offline --min-severity informational .github/workflows` (1.31.1) | no findings |
| gitleaks | `gitleaks dir . --config .gitleaks.toml --redact --no-banner` (8.30.1) | no leaks, about 273 KB scanned |

Pester by area:

| Test file | What it covers |
|---|---|
| `GuardHook.Tests.ps1` | 159 tests: 65 denied commands, 9 asks, 37 near misses that must be allowed, 18 secret patterns, 15 protected paths, 3 runs of the hook as a process with JSON on stdin |
| `Set-RepoGovernance.Tests.ps1`, `Test-RepoGovernance.Tests.ps1`, `New-GovernedRepo.Tests.ps1` | 79 tests (30, 32, 17): exact `gh api` arguments and JSON bodies, `-WhatIf` writes nothing, ruleset update by name vs create, 403/404/422 on plan-gated features become warnings, offline and online audit results, exit codes |
| `Test-PullRequest.Tests.ps1`, `Download.Tests.ps1`, `Invoke-LocalChecks.Tests.ps1` | 49 tests (35, 7, 7): title and section rules, comment-only sections, injection-looking text treated as data, Dependabot title-only mode, checksum match and mismatch, local check summary and exit codes |
| `Template.Tests.ps1` | 52 tests, policy as code: every action pinned by SHA, read-only permissions, no `pull_request_target`, `persist-credentials: false`, timeouts on every job, no PR text inside `run:`, required files present, ruleset and policy list the same checks, every check is a workflow job |

`Test-RepoGovernance.ps1 -Path .` (offline audit): **25 Pass, 0 Fail**, plus 1 Skip for the live checks (no `-Repository`).

Negative check: breaking `pr-policy.yml` on purpose (`persist-credentials: true`, the timeout removed, the PR title put inside `run:`) made exactly the three matching `Template.Tests.ps1` tests fail. With the file restored, 0 failed.

## 2. Live audit of this repository (2026-10-16, before any settings were applied)

`Test-RepoGovernance.ps1 -Path . -Repository kaushik-sai/governed-repo-template`, read-only, with a token that has push but not admin rights. Exit code 1, as expected: the repo was created with GitHub's defaults and `Set-RepoGovernance.ps1` had not been run yet.

| Result | Checks |
|---|---|
| Pass | the 25 offline checks; `allow_squash_merge`, `allow_auto_merge` |
| Fail, real drift | `allow_merge_commit` and `allow_rebase_merge` are on; `delete_branch_on_merge` is off; squash commit title and message are GitHub's defaults; wiki and projects are on; no ruleset named `protect-default-branch` |
| Fail, not visible to this token | secret scanning and push protection (GitHub only returns them to admins); Dependabot alerts (HTTP 403) |

This is the drift report the script is for. Running `Set-RepoGovernance.ps1` as the owner should turn every row to Pass.

## 3. CI on GitHub

First run on PR #1 (commit `c389e7e`): `lint`, `workflow-lint`, `secret-scan` and `pr-policy` passed. Two failed:

| Job | Cause | Fix |
|---|---|---|
| `test` | All 339 Pester tests passed, then the summary step failed: two tests reset `GITHUB_STEP_SUMMARY` to empty instead of restoring it | The tests now restore the original value. Reproduced locally with the variable set, then fixed |
| `dependency-review` | "Dependency review is not supported on this repository. Please ensure that Dependency graph is enabled" | Needs a repo admin: running `Set-RepoGovernance.ps1` turns on Dependabot alerts, which turns on the dependency graph, or enable it under Settings, Code security |

## Not verified yet

| What | Why | How to verify |
|---|---|---|
| The workflows on a GitHub runner (tool downloads, checksum file names, the zizmor `pip --require-hashes` install, the step summaries) | Only possible on GitHub | The first PR's runs (section 2) |
| `Set-RepoGovernance.ps1` and `Test-RepoGovernance.ps1 -Repository` against a real repo | No GitHub admin API access from the build session; every call is mocked in tests. The exact `gh` output for plan-gated 403/422 errors is assumed from GitHub's docs | Run both against this repo with `gh auth login` as the owner, `-WhatIf` first |
| `New-GovernedRepo.ps1` end to end | Same as above | Create a throwaway repo, audit it, delete it |
| The guard hook and permission rules inside a live Claude Code session | Tested as a script with JSON on stdin, not through Claude Code itself | Open the repo in Claude Code and try a denied command, such as `git push --force origin main` |
| The ruleset actually enforced | `Set-RepoGovernance.ps1` has not been run on this repo yet (it needs an admin token) | Run it as the owner, then try a direct push to `main`: it should be refused |
| Dependabot PR titles passing `pr-policy` | Needs a real Dependabot run | The first weekly Dependabot PR |
