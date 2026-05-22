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
