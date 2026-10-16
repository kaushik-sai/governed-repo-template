<!--
PR title: Conventional Commits, for example "feat(scripts): add repo audit" or "fix: handle 404 on private repos".
Every section below is checked by the pr-policy job. HTML comments do not count as content.
-->

## What changed

<!-- The visible change, in plain words. -->

## Why

<!-- The problem or the ticket. Link it. -->

## How it was verified

<!-- Commands run and their results, with numbers (for example "Pester: 112 passed, 0 failed"). Say what is not verified. -->

## Risk and rollback

<!-- What could break, who is affected, and how to undo it (revert this PR, re-run a script, and so on). -->

## AI assistance

<!-- Which parts an AI agent wrote or changed, and what a human checked. "None" is a valid answer. -->

## Checklist

- [ ] `pwsh ./scripts/Invoke-LocalChecks.ps1` passes
- [ ] Docs updated (README, DESIGN, RUNBOOK, docs/DECISIONS.md) where behaviour changed
- [ ] No secrets, tokens or internal hostnames in code, logs or this description
