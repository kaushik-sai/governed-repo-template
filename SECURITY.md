# Security policy

## Report a vulnerability

Report privately, never in a public issue or PR:

- **GitHub private vulnerability reporting:** the repository's **Security** tab, then **Report a vulnerability**. `Set-RepoGovernance.ps1` turns this on.
- Include what is affected, how to reproduce it, and the impact you expect. Do not include real secrets; describe them instead.

What happens next:

| Step | Target time |
|---|---|
| Acknowledge the report | 3 working days |
| First assessment (valid or not, severity) | 7 working days |
| Fix or mitigation for high and critical issues | 30 days |
| Public advisory, crediting the reporter if they want | when the fix is released |

## Supported versions

Only the latest commit on `main` is supported. Repositories made from this template own their own copy and their own security policy: update this file when you create one.

## What this repository does to stay safe

| Control | Where |
|---|---|
| Secrets never committed: gitleaks on every PR, on `main` and weekly over the full history; GitHub secret scanning with push protection where the plan allows | [.github/workflows/security.yml](.github/workflows/security.yml), [scripts/Set-RepoGovernance.ps1](scripts/Set-RepoGovernance.ps1) |
| Supply chain: every action pinned to a commit SHA; every downloaded tool checked against its published SHA-256; Python tools installed with `--require-hashes`; Dependabot with a 7-day cooldown | [.github/workflows/](.github/workflows/), [.github/dependabot.yml](.github/dependabot.yml) |
| Least privilege in CI: read-only `GITHUB_TOKEN`, `persist-credentials: false`, no `pull_request_target`, untrusted PR text passed only through environment variables | [tests/Template.Tests.ps1](tests/Template.Tests.ps1) enforces these |
| Workflow security lint: zizmor and actionlint | `workflow-lint` job in [.github/workflows/ci.yml](.github/workflows/ci.yml) |
| Branch protection as code: PR required, code owner review, required checks, no force push or deletion | [governance/rulesets/main.json](governance/rulesets/main.json) |
| AI agent guardrails: denied commands and secret files, a guard hook, protected paths that need a human | [.claude/settings.json](.claude/settings.json), [.claude/hooks/Invoke-GuardHook.ps1](.claude/hooks/Invoke-GuardHook.ps1) |

The threat model and what these controls do not cover are in [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md).

## If a secret leaks

Follow [RUNBOOK.md](RUNBOOK.md). Revoke the secret first; removing it from Git history comes after and is not enough on its own.
