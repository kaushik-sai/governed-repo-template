# AGENTS.md

Rules for any AI coding agent in this repository: GitHub Copilot, OpenAI Codex, Cursor, Claude Code and others. [CLAUDE.md](CLAUDE.md) has the full detail; the rules are the same. Humans follow [CONTRIBUTING.md](CONTRIBUTING.md).

## The repo

A GitHub template that makes new projects governed, secure and agent-ready. PowerShell 7 scripts in `scripts/`, Pester 5 tests in `tests/`, policy as code in `governance/`, CI in `.github/workflows/`. Code must run on Windows and Linux.

## Before you say "done"

```powershell
pwsh ./scripts/Invoke-LocalChecks.ps1
```

It runs PSScriptAnalyzer, Pester, actionlint, zizmor and gitleaks, the same checks as CI. Zero Error or Warning findings, zero failed tests.

## How to work

1. Restate the task as a short brief: goal, testable requirements, assumptions. Ask only what changes the outcome.
2. Read the files and tests involved before you write. Match their style.
3. Write the test first where practical. Every `gh` and `git` call goes through `Invoke-Cli` in `scripts/lib/Cli.ps1`, so tests can mock it.
4. Make small, focused changes. No new dependencies unless the task needs one; say why.
5. Verify with the checks above and by running the script itself. Report what you verified, with numbers, and what you did not.

## Pull requests

- Branch `<type>/<short-description>` from `main`.
- Title: a Conventional Commit (`feat:`, `fix:`, `docs:`, `ci:`, `security:` ...).
- Body: the template's sections `## What changed`, `## Why`, `## How it was verified`, `## Risk and rollback`, `## AI assistance`, each with real content. In `## AI assistance`, say what the agent wrote and what a human must check.
- A human reviews and merges. Agents never merge.

## Never

- Read, print or write secrets (`.env`, `*.pem`, `*.key`, `secrets/`, tokens).
- Push to `main`, force-push, or rewrite shared history.
- Use `--no-verify`, disable a workflow, or skip or delete a failing test.
- Change `.github/workflows/`, `governance/`, `.claude/`, `CODEOWNERS` or this file without a human asking for it.
- Pipe a download into a shell.
- Merge, delete, release or change GitHub settings without the user's go-ahead.
- Work around a guardrail. If something blocks you, stop and explain.

## Why the rules hold

Claude Code enforces some of these with a deny list and a guard hook ([docs/AGENT_WORKFLOW.md](docs/AGENT_WORKFLOW.md)). Other agents do not load those files. For every agent, the same CI checks, the branch ruleset and code-owner review apply on GitHub, where the agent has no say.
