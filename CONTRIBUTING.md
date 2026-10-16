# Contributing

Humans and AI agents follow the same rules. Agents also follow [CLAUDE.md](CLAUDE.md) (Claude Code) or [AGENTS.md](AGENTS.md) (other agents).

## The flow

1. **Start from an issue.** Use the bug, feature or agent-task form. An agent task needs testable requirements and acceptance criteria before work starts.
2. **Branch from `main`.** Name it `<type>/<short-description>`, for example `feat/repo-audit` or `fix/ruleset-404`. Nobody pushes to `main`; the ruleset blocks it.
3. **Write the test first** where it is practical. Every `gh` and `git` call goes through `Invoke-Cli` in [scripts/lib/Cli.ps1](scripts/lib/Cli.ps1), so tests mock it and need no network.
4. **Run the checks locally** before you push:

   ```powershell
   pwsh ./scripts/Invoke-LocalChecks.ps1
   ```

   This runs the same checks as CI: PSScriptAnalyzer, Pester, actionlint, zizmor and gitleaks. A missing tool is reported as skipped with how to install it.
5. **Open a PR** using the template. The title is a [Conventional Commit](https://www.conventionalcommits.org/en/v1.0.0/) (`feat:`, `fix:`, `docs:`, `ci:`, `security:` ...). Fill in every section; the `pr-policy` job checks them.
6. **Review.** One approval from a code owner, all conversations resolved, all required checks green, and a fresh approval after the last push. The PR is squash-merged and the branch deleted.

## Rules that are not negotiable

- No secrets in code, logs, issues or PRs. Use the platform's secret store and reference it by name.
- Pin every new action to a full commit SHA with a version comment, and every downloaded tool to a version and its SHA-256.
- Workflows get `permissions: contents: read` and add only what a job needs.
- Never skip, disable or quarantine a test to get green. Fix the cause or ask.
- A behaviour change updates the docs in the same PR, and a decision gets a numbered row in [docs/DECISIONS.md](docs/DECISIONS.md).

## Style

- PowerShell 7, 4-space indent, braces on the same line ([PSScriptAnalyzerSettings.psd1](PSScriptAnalyzerSettings.psd1)). Zero Error or Warning findings.
- One wrapper per external CLI. Scripts dot-source cleanly so tests can load their functions without running them.
- Docs in plain, short sentences. Say what is verified and what is not.
