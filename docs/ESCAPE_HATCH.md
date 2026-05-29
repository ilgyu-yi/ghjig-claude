# Escape Hatch

Full spec in [SPEC.md §7](../SPEC.md).

How to temporarily bypass a hook block.

## Form

```bash
SKIP_HOOKS=<category>[,<category>...] SKIP_REASON='<reason>' <command>
```

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
- `directive-protect` — `git checkout -b <user>/<type>/<N>-<slug>` blocked because `<N>` is a Directive Issue (SPEC §1.7 / §6.1 type-aware hook). Directives are gated by `/complete-directive` + `activation-reviewer`, not engineering-flow `Closes #N` semantics. First-line remedy: `/activate-directive <N>` (if Proposed) or `/file-issue --parent <N>` then `/work-on` the new Issue (if Active). Escape is for cases where the maintainer explicitly wants to repurpose the Directive Issue as an Execution branch — rare and audit-logged.
- `trusted-filer-mutate` — `gh issue close <N>` on a trusted-filer (OWNER/MEMBER/MAINTAINER/COLLABORATOR per `authorAssociation`) Issue without `--reason completed`, OR `gh issue edit <N> --remove-label directive` on ANY filer. Mode-independent (applies in both `attended` and `unattended`). First-line remedy for Directive completion: use `/complete-directive` (closes with `--reason completed` after reviewer evidence pass). For declassification: human confirm required — explicit escape is the documented path. SPEC §1.5 filer-aware invariants.
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
