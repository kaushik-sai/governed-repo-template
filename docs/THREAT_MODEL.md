# Threat model

What this template protects, from whom, and what it does **not** cover. Short on purpose; repos made from the template extend it with their own assets.

## Assets

| Asset | Why it matters |
|---|---|
| The `main` branch | It is what ships. Anything merged runs in production or in other people's pipelines |
| Secrets (cloud keys, tokens, passwords) | One leaked secret can give access far beyond this repo |
| The CI token (`GITHUB_TOKEN`) and runner | A workflow with write access can push code or tamper with releases |
| The governance files (`governance/`, `.github/`, `.claude/`) | They define what every other change is checked against |

## Threats and controls

| # | Threat | Control | Layer |
|---|---|---|---|
| T1 | A change reaches `main` without review | Ruleset: PR required, code owner review, last-push approval, no direct push, no force push | GitHub (server side) |
| T2 | A secret is committed | gitleaks in CI over full history; push protection where the plan allows; the agent guard hook blocks secret-looking content; `.gitignore` covers `.env`, keys | CI, GitHub, agent |
| T3 | A compromised or moved action tag runs in CI | Every action pinned to a commit SHA; `tests/Template.Tests.ps1` fails on an unpinned `uses:` | CI |
| T4 | A tampered tool download | SHA-256 check against the release's published checksums; `pip --require-hashes` | CI |
| T5 | Script injection through PR titles, bodies or branch names | Untrusted text passed only via `env:`; a test forbids `${{ github.event.pull_request.title }}`, `.body` and `github.head_ref` inside `run:`; zizmor checks the rest | CI |
| T6 | A fork PR steals the token | No `pull_request_target`; read-only token; `persist-credentials: false` | CI |
| T7 | An AI agent does something destructive (force push, deletes, merges) | Settings deny rules; guard hook denies; ask rules for pushes and PR creation; the ruleset blocks what slips past | Agent, GitHub |
| T8 | An AI agent weakens the rules it is checked against | Edits to workflows, `governance/` and `.claude/settings.json` always ask a human; CODEOWNERS requires the owner's review for those paths | Agent, GitHub |
| T9 | Prompt injection through issues, PR comments or fetched pages | Agent docs say to treat them as data; outward actions need confirmation; the agent's GitHub token is the user's, scoped by the GitHub App installation | Agent, process |
| T10 | Settings drift in the GitHub UI | `Test-RepoGovernance.ps1` compares live settings with the policy; `Set-RepoGovernance.ps1` restores them | Process |
| T11 | A vulnerable dependency | Dependabot alerts and security updates; dependency review on PRs (public repos, or private with Advanced Security) | GitHub |

## What this does not cover

- **A malicious maintainer.** An admin can change the ruleset. Audit logs and an organization ruleset (which repo admins cannot edit) are the next step.
- **Private repos on GitHub Free.** Rulesets, secret scanning, push protection and dependency review are not enforced there. The scripts say so (Warn), but the control is off. CI still runs gitleaks.
- **Runtime security** of whatever the repo deploys. That belongs in the project's own DESIGN and threat model.
- **The guard hook is not a sandbox.** It matches command text. A determined agent or a creative spelling can get past it, which is why it is one layer of four and fails open (docs/DECISIONS.md #18).
- **Self-hosted runners.** The template assumes GitHub-hosted runners, which are fresh for every job. Self-hosted runners need their own hardening.
