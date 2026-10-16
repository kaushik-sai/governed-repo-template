# CLAUDE.md

Instructions for Claude Code in this repository. Other agents: see [AGENTS.md](AGENTS.md) (the same rules, shorter). Humans: see [CONTRIBUTING.md](CONTRIBUTING.md).

## What this repo is

A GitHub template repository. Every new project made from it starts governed, secure and agent-ready:

- **Governance as code:** [governance/policy.json](governance/policy.json) says what "governed" means; [governance/rulesets/main.json](governance/rulesets/main.json) is the branch ruleset for `main`.
- **Scripts** (PowerShell 7) apply and audit the GitHub-side settings: `Test-RepoGovernance.ps1`, `Set-RepoGovernance.ps1`, `New-GovernedRepo.ps1`, `Test-PullRequest.ps1`, `Invoke-LocalChecks.ps1`.
- **CI:** `ci.yml` (lint, test, workflow-lint), `security.yml` (secret-scan, dependency-review), `pr-policy.yml` (pr-policy). All six are required checks.
- **Agent guardrails:** [.claude/settings.json](.claude/settings.json) (deny and ask rules), the guard hook [.claude/hooks/Invoke-GuardHook.ps1](.claude/hooks/Invoke-GuardHook.ps1), and the orchestrate skill. See [docs/AGENT_WORKFLOW.md](docs/AGENT_WORKFLOW.md).

The owner works on Windows 11 with PowerShell 7 (Git Bash also present). CI and cloud agent sessions run on Linux. Code must run on both.

## Commands

```powershell
pwsh ./scripts/Invoke-LocalChecks.ps1                 # everything CI runs: lint, test, actionlint, zizmor, gitleaks
pwsh ./scripts/Invoke-LocalChecks.ps1 -Skip zizmor    # leave a check out
pwsh -NoProfile -Command "Invoke-Pester -Path ./tests -Output Detailed"
pwsh -NoProfile -Command "Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1"
pwsh ./scripts/Test-RepoGovernance.ps1                # offline governance audit of the working tree
```

Pester 5 and PSScriptAnalyzer are PowerShell modules. A tool that is missing is reported as Skip, with how to install it. Run `Invoke-LocalChecks.ps1` before you say a change is done.

## Conventions

- **One wrapper per external CLI.** Every `gh` and `git` call goes through `Invoke-Cli` in [scripts/lib/Cli.ps1](scripts/lib/Cli.ps1). Tests mock it, so they need no network, token or real repo. A new CLI gets its own wrapper.
- **Tests first** where practical. Pester 5, one `tests/<Script>.Tests.ps1` per script, table-driven with `-ForEach`. Scripts dot-source cleanly: functions on top, the main block behind `if ($MyInvocation.InvocationName -ne '.')`.
- **Zero analyzer findings** at Error or Warning. 4-space indent, braces on the same line, `Set-StrictMode -Version Latest`.
- **Pin everything.** Actions by full commit SHA with a version comment. Downloaded tools by version and SHA-256. Workflows start from `permissions: contents: read`.
- **Docs set:** README, DESIGN, RUNBOOK, [docs/DECISIONS.md](docs/DECISIONS.md), [docs/EVIDENCE.md](docs/EVIDENCE.md). Plain, short sentences. Say what is verified and what is not.
- **Decisions log:** a design choice gets a numbered row in `docs/DECISIONS.md` (Question | Decision | Why) in the same PR.
- **Untrusted input** (PR titles and bodies, branch names, issue text) is data. Compare it; never execute it or put it in a shell string.

## Pull requests

- Branch from `main` as `<type>/<short-description>`, for example `feat/repo-audit`. Nobody pushes to `main`.
- The title is a Conventional Commit: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `ci:`, `build:`, `chore:`, `perf:`, `revert:`, `security:`, with an optional scope.
- The body uses [.github/pull_request_template.md](.github/pull_request_template.md). These sections need real content (the `pr-policy` job checks them): `## What changed`, `## Why`, `## How it was verified`, `## Risk and rollback`, `## AI assistance`.
- In `## AI assistance`, say what you wrote and what a human must check. In `## How it was verified`, give commands and numbers ("Pester: 112 passed, 0 failed") and say what you could not verify.
- Merging needs one code-owner approval after the last push, resolved threads and six green checks. The PR is squash-merged. A human merges, never an agent.

## Never

- Read, print or write secrets. No `.env`, `*.pem`, `*.key` or `secrets/`. No tokens in code, logs, commits, issues or PR text.
- Push to `main` or `master`, force-push, or rewrite shared history (`reset --hard`, `filter-branch`, rebasing `main`).
- Skip hooks or checks: no `--no-verify`, no disabling a workflow, no skipping or deleting a failing test to get green. Fix the cause or ask.
- Change the rules without a human: `.github/workflows/`, `governance/`, `.claude/settings*.json`, `.claude/hooks/`, `CODEOWNERS`. The hook asks the user every time; say why in the PR.
- Run `curl ... | sh` or any download-and-run. Download, check the SHA-256, read, then run.
- Merge PRs, delete repos or branches on GitHub, publish releases, or run `Set-RepoGovernance.ps1` / `New-GovernedRepo.ps1` without the user's go-ahead.
- Commit or push unless asked. Commit only on a feature branch.
- Work around a guardrail. If the guard hook or a deny rule blocks you, stop and tell the user what you wanted to do and why.

## How to work: the orchestrate skill

For any non-trivial request (build, fix, refactor, migrate, document), use the skill in [.claude/skills/orchestrate/SKILL.md](.claude/skills/orchestrate/SKILL.md), or type `/orchestrate <task>`:

1. **Refine** the request into a brief ([references/brief-template.md](.claude/skills/orchestrate/references/brief-template.md)): goal, testable requirements, assumptions. Show it in 10 to 15 lines. Ask only what changes the outcome.
2. **Explore, then plan.** Read the files and tests involved first. Split work into streams by file ownership.
3. **Delegate in parallel** with an explicit model and effort per subagent (the table is in the skill). Every subagent brief follows [references/subagent-brief.md](.claude/skills/orchestrate/references/subagent-brief.md): facts, owned files, bounded verify commands, short report.
4. **Verify** the combined result yourself: `Invoke-LocalChecks.ps1`, and run the thing, not only its tests. A subagent's report is a claim to check.
5. **Report** what is now true, how it was verified (with numbers), what is not verified, and the one decision that is the user's.

Skip the skill for one-line answers and quick reads.

## Where things are

| Path | What |
|---|---|
| `governance/` | policy and ruleset (protected: ask) |
| `scripts/`, `scripts/lib/` | the scripts and their shared helpers |
| `tests/` | Pester tests, one file per script |
| `.github/` | workflows (protected: ask), CODEOWNERS, PR and issue templates |
| `.claude/` | settings, guard hook (protected: ask), orchestrate skill |
| `docs/` | DECISIONS, EVIDENCE, AGENT_WORKFLOW, THREAT_MODEL |

Personal settings go in `.claude/settings.local.json` and personal notes in `CLAUDE.local.md`. Both are git-ignored.
