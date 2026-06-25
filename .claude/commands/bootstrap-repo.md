---
description: Stage-0 bootstrap — take a brand-new target with no default branch (empty repo / unborn HEAD) to a seedable default branch ready for /onboard. Owns the scoped, audit-logged first-commit exception.
argument-hint: ""
---

Stage-0 of the adoption lifecycle (SPEC §5.0). Runs **before** `/onboard` (§5.1) on a brand-new target that has **no default branch** — an empty GitHub repo (zero commits) or a freshly `git init`'d greenfield directory (unborn HEAD). The lifecycle `clone-into.sh` → `register.sh` → `/onboard` → `/onboard-dir-mode` presupposes a default branch with a prior commit exists; `/bootstrap-repo` is the step that produces it, so the no-default-branch starting state has an owner instead of ad-hoc manual git.

Outputs a default branch (`main`) carrying a single seed commit — `MISSION.md` (from `.claude/templates/mission.md`, a draft for the user to complete) and `README.md` (from `.claude/templates/readme_for_target.md`) — pushed to the remote, ready for `/onboard`. Stage-0 seeds **only** these two SSOT files; `.github/` templates, labels, and substrate are `/onboard` / `/onboard-dir-mode` concerns.

## The bootstrap exception (why this skill owns an escape)

The protected-branch gate (SPEC §6.1) is **name-based** (`PROTECTED_BRANCH_PATTERN`). On an unborn HEAD, `git symbolic-ref --short HEAD` returns `main` (rc=0) while `git rev-parse --verify HEAD` fails, so `is_protected_branch()` matches by name and the seed commit — plus the Edit/Write that authors `MISSION.md`/`README.md` on that branch — is blocked. That is **correct, desirable behavior for the general case**; `/bootstrap-repo` does **not** weaken the gate. It owns a single, **scoped, audit-logged** bypass for *this one seed commit only*, via the existing `branch` escape (SPEC §7).

Because this skill runs **in-harness** (the live Bash tool strips both in-command escape forms before the hook sees them, #478), the seed commit uses the **file-based skip token** (SPEC §7) — the in-agent channel the harness cannot strip. Write a `branch`-category token whose fingerprint is the seed-commit subject, immediately before the commit:

```
scripts/eng_skip.sh branch 'chore: seed first commit (MISSION + README)' 'stage-0-bootstrap-seed-on-unborn-HEAD'
git commit -m "chore: seed first commit (MISSION + README)"
```

The hook reads the token at fire time, audits it, and **consumes** it; the bypass routes through `should_skip branch` and lands in `audit.jsonl` — never silent. (Running the seed commit in a **real terminal** is the fallback.) This generalizes the shell's own-repo first-commit exception (SPEC §16 item 15) to target repos: both are the same chicken-and-egg (a first commit cannot ride a flow that presupposes a prior commit), and both keep the bypass observable in the audit log.

## Procedure

1. **Preflight** — refuse (and stop) if any of:
   - Not inside a git work tree (`git rev-parse --is-inside-work-tree` fails) → `"not a git repository — run 'git init' first, or /onboard if the repo already exists."`
   - A default branch already exists (`git rev-parse --verify HEAD` succeeds) → `"target already has a default branch — run /onboard, not /bootstrap-repo."` The repo is past stage-0.
   - The working tree already has staged or committed content beyond the unborn state → stop and surface; stage-0 seeds an empty repo only.

2. **Confirm the seed** — surface to the user (attended) the two files that will be seeded and the remote that will receive the push (`git remote get-url origin`, if set). If no `origin` remote is configured, note that the push step is skipped and the operator must add a remote + push manually.

3. **Seed the SSOT files** — copy the two templates into place **with Bash `cp`, not the Edit/Write tool**:
   ```bash
   cp "$CLAUDE_ENG_SHELL_ROOT/.claude/templates/mission.md" MISSION.md
   cp "$CLAUDE_ENG_SHELL_ROOT/.claude/templates/readme_for_target.md" README.md
   ```
   Why `cp` and not Write: the Edit/Write protected-branch arm (SPEC §6.1) blocks writes on the unborn-HEAD `main`, and a trailing sentinel cannot disarm it (an Edit/Write tool call has no command string to carry the sentinel). A `cp` into the registered target path carries no protected-branch check and is in-scope, so it is the correct seeding path. The templates carry `{{ today }}` / `{{ repo_name }}` placeholders — these are drafts for the user to complete after bootstrap; substitute them now only if the values are unambiguous (e.g. `{{ repo_name }}` from `basename "$PWD"`), otherwise leave them for `/onboard`'s SSOT step to flag.

4. **Seed commit** — stage exactly the two seed files, write the `branch` file token (fingerprint = the seed-commit subject), then commit:
   ```bash
   git add MISSION.md README.md
   scripts/eng_skip.sh branch 'chore: seed first commit (MISSION + README)' 'stage-0-bootstrap-seed-on-unborn-HEAD'
   git commit -m "chore: seed first commit (MISSION + README)"
   ```
   The token is one-shot (consumed on read, 60s TTL — SPEC §7); running the commit in a real terminal is the fallback. The message is a `chore` (no issue # required — there is no issue tracker state yet).

5. **Audit** — the seed commit's bypass is *already* recorded by the `branch` escape's `should_skip` path (this is the load-bearing audit guarantee — never silent). Additionally emit an explicit stage-0 record by sourcing the hook runtime and calling `audit_log info bootstrap-repo seeded "branch=main remote=<origin-url-or-none> files=MISSION.md,README.md"` (run via Bash: `. "$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/hookrt.sh"` then the `audit_log` call), the same pattern `/file-directive` etc. use.

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
- Bypassing the protected-branch gate with either in-command form in-harness — both are stripped before the hook; use the `scripts/eng_skip.sh branch` file token (SPEC §7).
- Force-pushing or pushing a bare/`HEAD` refspec — name the branch (`origin main`) explicitly.
