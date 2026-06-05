---
description: Stage-0 bootstrap — take a brand-new target with no default branch (empty repo / unborn HEAD) to a seedable default branch ready for /onboard. Owns the scoped, audit-logged first-commit exception.
argument-hint: ""
---

Stage-0 of the adoption lifecycle (SPEC §5.0). Runs **before** `/onboard` (§5.1) on a brand-new target that has **no default branch** — an empty GitHub repo (zero commits) or a freshly `git init`'d greenfield directory (unborn HEAD). The lifecycle `clone-into.sh` → `register.sh` → `/onboard` → `/onboard-dir-mode` presupposes a default branch with a prior commit exists; `/bootstrap-repo` is the step that produces it, so the no-default-branch starting state has an owner instead of ad-hoc manual git.

Outputs a default branch (`main`) carrying a single seed commit — `MISSION.md` (from `.claude/templates/mission.md`, a draft for the user to complete) and `README.md` (from `.claude/templates/readme_for_target.md`) — pushed to the remote, ready for `/onboard`. Stage-0 seeds **only** these two SSOT files; `.github/` templates, labels, and substrate are `/onboard` / `/onboard-dir-mode` concerns.

## The bootstrap exception (why this skill owns an escape)

The protected-branch gate (SPEC §6.1) is **name-based** (`PROTECTED_BRANCH_PATTERN`). On an unborn HEAD, `git symbolic-ref --short HEAD` returns `main` (rc=0) while `git rev-parse --verify HEAD` fails, so `is_protected_branch()` matches by name and the seed commit — plus the Edit/Write that authors `MISSION.md`/`README.md` on that branch — is blocked. That is **correct, desirable behavior for the general case**; `/bootstrap-repo` does **not** weaken the gate. It owns a single, **scoped, audit-logged** bypass for *this one seed commit only*, via the existing `branch` escape (SPEC §7).

Because this skill runs **in-harness** (the live Bash tool consumes a leading `VAR=` env-prefix before the hook sees it), the seed commit uses the **trailing-sentinel** escape form — the leading `SKIP_HOOKS=branch` form would be stripped before the hook and would not disarm the matcher. The exact, audit-greppable invocation is:

```
git commit -m "chore: seed first commit (MISSION + README)"  # claude-eng:skip=branch reason=stage-0-bootstrap-seed-on-unborn-HEAD
```

The bypass routes through `should_skip branch` and lands in `audit.jsonl` — never silent. This generalizes the shell's own-repo first-commit exception (SPEC §16 item 15) to target repos: both are the same chicken-and-egg (a first commit cannot ride a flow that presupposes a prior commit), and both keep the bypass observable in the audit log.

## Procedure

1. **Preflight** — refuse (and stop) if any of:
   - Not inside a git work tree (`git rev-parse --is-inside-work-tree` fails) → `"not a git repository — run 'git init' first, or /onboard if the repo already exists."`
   - A default branch already exists (`git rev-parse --verify HEAD` succeeds) → `"target already has a default branch — run /onboard, not /bootstrap-repo."` The repo is past stage-0.
   - The working tree already has staged or committed content beyond the unborn state → stop and surface; stage-0 seeds an empty repo only.

2. **Confirm the seed** — surface to the user (attended) the two files that will be seeded and the remote that will receive the push (`git remote get-url origin`, if set). If no `origin` remote is configured, note that the push step is skipped and the operator must add a remote + push manually.

3. **Seed the SSOT files** — write `MISSION.md` from `.claude/templates/mission.md` (substituting `{{ today }}`) and `README.md` from `.claude/templates/readme_for_target.md` (substituting `{{ repo_name }}`). These Writes occur on the unborn-HEAD `main` and are covered by the same `branch` exception — the Edit/Write protected-branch arm (SPEC §6.1) is disarmed for the seed only.

4. **Seed commit** — stage exactly the two seed files and commit with the exact escape sentinel:
   ```bash
   git add MISSION.md README.md
   git commit -m "chore: seed first commit (MISSION + README)"  # claude-eng:skip=branch reason=stage-0-bootstrap-seed-on-unborn-HEAD
   ```
   The message is a `chore` (no issue # required — there is no issue tracker state yet).

5. **Audit** — `audit_log info bootstrap-repo seeded "branch=main remote=<origin-url-or-none> files=MISSION.md,README.md"`.

6. **Publish** — if an `origin` remote exists, `git push -u origin main` (name the branch explicitly; a bare/`HEAD` refspec is not verifiable by the push matcher, SPEC §6.1). GitHub adopts the first pushed branch as the repo default. If no remote, print the manual `git remote add origin <url> && git push -u origin main` follow-up.

7. **Handoff** — print:
   ```
   Bootstrapped: default branch 'main' seeded (MISSION.md + README.md) and pushed.
   Next: /onboard
   ```

## Operating mode

- **attended**: step 2 confirms the seed with the user before writing.
- **unattended**: step 2 proceeds without prompting (no human present); the preflight refusals in step 1 still gate.

## Escape

The skill's seed commit *is* the documented `branch` escape (audit-logged). No additional escape is needed; do not broaden it past the single seed commit.

## Forbidden

- Running on a repo that already has a default branch / prior commits — step 1 refuses.
- Using the `branch` escape for anything other than the single seed commit — the exception is scoped to stage-0, not a general bypass.
- Seeding anything beyond `MISSION.md` + `README.md` — `.github/`, labels, and substrate belong to `/onboard` and `/onboard-dir-mode`.
- Bypassing the protected-branch gate with the leading `SKIP_HOOKS=branch` form in-harness — it is stripped before the hook; use the trailing sentinel.
- Force-pushing or pushing a bare/`HEAD` refspec — name the branch (`origin main`) explicitly.
