# RUNBOOK: a secret was committed

**Scenario.** The `secret-scan` job fails on a PR, or GitHub push protection or a secret scanning alert fires. A token, key or password is in a commit. It may already be on GitHub, in a fork, or in a CI log.

The order matters: **revoke first, clean up second.** Removing a secret from Git does not make it safe. Assume it was copied the moment it was pushed.

**Where to look**
| What | Where |
|---|---|
| Which file, line and commit | The `secret-scan` job's summary (the value is redacted), or locally `gitleaks git . --redact --no-banner` |
| GitHub's own alerts (where the plan has secret scanning) | Repository **Security** tab, **Secret scanning** |
| Whether the PR is from a fork | The PR header. A fork keeps its own copy of the commit |
| Who can see the repo | Settings, **General**, visibility; and **Collaborators and teams** |

## First 30 minutes

| Time | Action |
|---|---|
| 0:00 | **Stop the spread.** Do not merge the PR. If it is already merged, keep going; do not try to "fix it in the next commit". |
| 0:02 | **Identify the secret** from the scan output: its type (GitHub token, cloud key, database password) and which system it opens. Do not paste the value into chat, tickets or this runbook. |
| 0:05 | **Revoke or rotate it** in the system that issued it (the cloud console, GitHub **Settings > Developer settings**, the database). Create the replacement and store it only in the secret store (GitHub Actions secrets, a key vault). This is the step that actually removes the risk. |
| 0:10 | **Check for use.** Look at the issuing system's audit log for activity with the old secret since the commit time. Unexpected activity makes this a security incident: tell the security contact in [SECURITY.md](SECURITY.md) now. |
| 0:15 | **Fix the branch.** If the commit is only on an unmerged branch, rewrite that branch (commands below) and force-push the branch only. `main` is never force-pushed; the ruleset blocks it. |
| 0:20 | **If it reached `main`:** the secret is revoked, so leaving it in history is a hygiene problem, not an open door. Remove it from the current files with a normal PR. Rewriting `main`'s history needs an admin to lift the ruleset temporarily and every clone to re-clone; do it only if policy requires it, and record the decision. |
| 0:25 | **Verify:** `gitleaks git . --redact --no-banner` is clean on the branch, the `secret-scan` job is green, and the old secret no longer works (try it once, from a safe place). |
| 0:30 | **Record** what happened in the incident ticket: what leaked, when it was revoked, whether it was used, and the follow-up below. |

## Commands

```powershell
# From the repo root, PowerShell 7.

# 1. Find every leak in the branch's history (values are redacted in the output).
gitleaks git . --redact --no-banner --log-opts="origin/main..HEAD"

# 2. Unmerged branch only: remove the commit that added the secret, then force-push THIS branch.
#    Interactive rebase is simplest by hand; drop or edit the offending commit.
git fetch origin main
git rebase -i origin/main
git push --force-with-lease origin HEAD

# 3. Confirm the branch is clean again.
gitleaks git . --redact --no-banner --log-opts="origin/main..HEAD"

# 4. Check the repo's governance is still in place after any temporary admin change.
pwsh ./scripts/Test-RepoGovernance.ps1 -Path . -Repository <owner>/<name>
```

The guard hook in `.claude/hooks/` blocks force pushes from an AI agent. Run step 2 yourself.

## Why the scan failed when nothing leaked (false positive)

gitleaks can flag test fixtures or example values. Do not weaken the scan. Instead:
1. Make the value obviously fake (`EXAMPLE`, `xxxx`) if you can.
2. Otherwise add the exact fingerprint from the scan output to a `.gitleaksignore` file in a PR, with a one-line reason. A code owner reviews it like any other change.

## Who to tell, and when

| Who | When |
|---|---|
| The owner of the leaked secret's system | At 0:05, when revoking |
| The security contact ([SECURITY.md](SECURITY.md)) | At 0:10 if the secret was used, or if it was a production credential at all |
| The PR author and reviewers | When the branch is fixed, with what to re-clone if history changed |

## Post-incident (blameless)

1. Timeline: commit time, detection, revocation, verification.
2. How it got in: which control could have stopped it earlier (local `Invoke-LocalChecks.ps1`, push protection, the agent guard hook)?
3. One change that makes it less likely, as a PR with a [docs/DECISIONS.md](docs/DECISIONS.md) row if it changes policy.

# RUNBOOK: governance drift

**Scenario.** Someone changed a branch rule or a repo setting in the GitHub UI, or a new repo was created without the template.

```powershell
# What is different from the policy? Exit code 1 means at least one Fail.
pwsh ./scripts/Test-RepoGovernance.ps1 -Path . -Repository <owner>/<name>

# Show what applying the policy would change, then apply it.
pwsh ./scripts/Set-RepoGovernance.ps1 -Repository <owner>/<name> -WhatIf
pwsh ./scripts/Set-RepoGovernance.ps1 -Repository <owner>/<name>
```

If the UI change was intended, change `governance/policy.json` or `governance/rulesets/main.json` in a PR instead, so the next run does not undo it.
