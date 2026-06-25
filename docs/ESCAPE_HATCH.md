# Escape Hatch

Full spec in [SPEC.md §7](../SPEC.md).

How to temporarily bypass a hook block.

## Form

Two forms, chosen by **where** the escape is read (full contract: [SPEC.md §7](../SPEC.md)).

**Trailing sentinel** — the form that survives the **live Claude Code Bash tool** (use this in-harness):

```bash
<command>  # claude-eng:skip=<category>[,<category>...] reason=<reason>
```

The harness consumes a leading `VAR=val` as the spawned subprocess's own environment, so the leading env-prefix below never reaches the hook in-harness (#206); a trailing `#`-comment stays in the command and is ignored by the executed shell. The sentinel's `#` must be a **genuine unquoted comment token** — a `#` inside a quoted argument is argument text, not an escape (#208).

**Leading env-prefix** — works only where the prefix arrives *inside* the command string (a real shell that passes it verbatim, and the smoke harness):

```bash
SKIP_HOOKS=<category>[,<category>...] SKIP_REASON='<reason>' <command>
```

If both are present, the **leading form wins**.

## Categories

- `all` — emergencies only.
- `secret` — secret pattern detected in staged diff. Persistent false positives (doc/test fixtures, ADR examples) should be added to `.shellsecretignore` at the target-repo root (gitignore-narrow globs) instead of repeated `SKIP_HOOKS=secret`. Allow-list is read from `HEAD`, so introducing a new entry requires its own commit before it takes effect — preventing same-commit self-bypass.
- `branch` — commit/push/edit on a protected branch.
- `commit-format` — Conventional Commit format violation.
- `format` — lint failure at commit time.
- `force-push` — force push.
- `amend` — `--amend` after push.
- `no-verify` — `git commit --no-verify`.
- `destructive` — `git reset --hard`, `git clean -f`, etc.
- `sensitive` — edit to `.env`/`*.pem`/`credentials*`.
- `out-of-scope` — Edit/Write outside registry, or `rm`/`mv`/`cp -f` args pointing outside registry.
- `ac-closeout` — `gh pr merge` blocked because a linked issue (`closingIssuesReferences`) has unchecked AC items and no `^## AC closeout` marker comment yet. First-line remedy: run `scripts/ac_closeout.sh <pr-num>` (idempotent; posts the comment if missing, skips if present). Escape category exists for legitimate edge cases — emergency merges, issues with no AC, etc. — and is audit-logged like any other skip.
- `proposed-protect` — `git checkout -b <user>/<type>/<N>-<slug>` blocked because `<N>` is `status:proposed` (any type) or a Directive (any status) (SPEC §1.7 / §6.1 type-aware hook; generalized from `directive-protect` by #171). `status:proposed` Issues are not yet actionable (gated by `/activate <N>`); Directives are gated by `/complete-directive` + `activation-reviewer`, not engineering-flow `Closes #N` semantics. First-line remedy: for a `status:proposed` Issue run `/activate <N>` first; for a Directive use `/file-issue --parent <N>` then `/work-on` the new Issue. Escape is for cases where the maintainer explicitly wants to branch the Issue anyway — rare and audit-logged.
- `label-parent-consistency` — `gh issue edit <N> --add-label {execution|task|bug}` blocked because the label contradicts the Issue body's line-1 `Parent Directive: #N` marker: `execution` with **no** marker, or `task`/`bug` **with** a marker present (SPEC §1.7 / §6.1; #199). Also (#251) blocks `--add-label initiative` on a `directive` Issue and `--add-label directive` on an `initiative` Issue (the two tier type-keys are mutually exclusive), and `--add-label directive` when the Directive body lacks exactly one parent kind — a `## MISSION fit` field XOR a line-1 `Parent Initiative: #N` marker (both, or neither). First-line remedy: set the marker via `/link-directive <D> <N>` then `--add-label execution`, or relabel to match the Issue's actual type. Escape is for a legitimate mid-edit two-step.
- `initiative-readonly` — a mutating `gh issue {edit|close|reopen}` (including `--add-label`/`--remove-label`/`--body`/`--title`) targeting an `initiative` Issue blocked: an Initiative is read-only to the shell except for appended comments — the shell *consumes* Initiatives, it never edits, closes, relabels, or retires them (SPEC §1.7, #251). First-line remedy: use `gh issue comment <N>` to surface findings upward (a challenge or completion comment); strategic decisions on an Initiative — revise, retire, accept — belong upstream, not inside the shell. Escape is for a sanctioned maintainer edit.
- `trusted-filer-mutate` — `gh issue close <N>` on a trusted-filer (OWNER/MEMBER/MAINTAINER/COLLABORATOR per `authorAssociation`) Issue without `--reason completed`, OR `gh issue edit <N> --remove-label directive` on ANY filer. Mode-independent (applies in both `attended` and `unattended`). First-line remedy for Directive completion: use `/complete-directive` (closes with `--reason completed` after reviewer evidence pass). For declassification: human confirm required — explicit escape is the documented path. SPEC §1.5 filer-aware invariants.
- `directive-close` — a `gh pr create`/`gh pr edit --body` or a commit message contains a GitHub close keyword (`close`/`closes`/`closed`, `fix`/`fixes`/`fixed`, `resolve`/`resolves`/`resolved`) before `#N` where `#N` is a **Directive**: GitHub would auto-close it at merge, bypassing `/complete-directive`'s signal gate (SPEC §6.1, #490). First-line remedy: use `Refs #N` or `advances #N` instead of a close keyword (Execution Issues are unaffected). Escape is for a sanctioned exception.
- `directive-review` — `activation-reviewer` returned `block: <reason>` on a `/file-directive` / `/activate-directive` / `/complete-directive` / `/revise-directive` invocation. First-line remedy: address the reviewer's reason and re-run. Escape exists for cases where the reviewer's verdict is wrong and a human accepts the recorded responsibility — not a normalized routing. `/block-directive` is annotation-only (no body change) and has no review-skip variant.
- `substrate-preflight` — a dir-mode command refused because the target lacks the substrate (`gh label list | grep -qx directive` returned nothing). First-line remedy: `/onboard-dir-mode --tier 2` (or `--tier 3`) installs the substrate via a PR to the target. Escape is for cases where `gh` is down and the maintainer knows the substrate is in place.

## Examples

```bash
SKIP_HOOKS=force-push SKIP_REASON='cleaning up bad history from rebase' git push --force-with-lease

SKIP_HOOKS=format SKIP_REASON='formatter lockfile conflict; will fix in next commit' git commit -m "feat(#42): partial"

SKIP_HOOKS=out-of-scope SKIP_REASON='ad-hoc cache cleanup' rm -rf /tmp/some-cache
```

## Policy

- Skips should be temporary.
- A skip with no `SKIP_REASON` is logged as `unspecified` — easy review target.
- Use `all` only in emergencies.
- A category that gets skipped repeatedly is a sign the hook is misconfigured — open a PR to fix it (for `secret`, that means adding the path to `.shellsecretignore`, not normalizing the bypass).

Every skip is recorded as one line of JSON in `.claude/audit/audit.jsonl`.
