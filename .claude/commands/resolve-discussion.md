---
description: Close a discussion-tier Issue (SPEC §5.19) via exactly one of two paths — promoted (concrete Issue filed) or no-action (nothing to do).
argument-hint: <issue-#> [--promoted-to <M> | --no-action <one-line-reason>]
---

Close a `discussion`-labeled Issue. Per SPEC §5.19 the tier has exactly two close paths; this skill enforces them.

## Procedure

1. **Parse `$ARGUMENTS`** — `<issue-#>` is required. Then either `--promoted-to <M>` or `--no-action "<reason>"`. If neither flag (or both): error and stop with a one-line usage reminder.

2. **Fetch the Issue**:
   ```bash
   gh issue view <issue-#> --json title,state,labels
   ```
   - If `state != OPEN`: error ("Issue #<N> is not open — current state `<X>`") and stop.
   - If `discussion` label absent: error ("Issue #<N> is not a discussion (label `discussion` missing)") and stop.

3. **Idempotency check** — if the latest comment on the Issue is `^promoted to #<M>$` matching the current `--promoted-to <M>` arg (or matches the `--no-action` reason verbatim), emit "already-resolved (idempotent no-op)" and stop.

4. **Branch on mode**:

   ### 4a. `--promoted-to <M>` (concrete Issue path)
   - Verify Issue `<M>` exists: `gh issue view <M> --json number,state,title`. If not found: error and stop.
   - Post comment on `<issue-#>`: `promoted to #<M>` (single line; the marker is the parser-facing convention).
   - Close: `gh issue close <issue-#> --reason completed`.
   - Post cross-reference comment on `<M>`: `Promoted from discussion #<issue-#>`. (Skip if the same marker is already in `<M>`'s recent comments — idempotency.)

   ### 4b. `--no-action "<reason>"` (no-action path)
   - Reason must be non-empty. Empty → error and stop.
   - Post comment on `<issue-#>` via `--body-file` (#504): write `no-action: <reason>` (single line) to a temp file, then `gh issue comment <issue-#> --body-file <file>`. Never inline `--body` with the free-text reason — a backtick / `$(...)` / quote would corrupt the comment or execute at assembly (the dir-mode `--body-file` bar). Keep the leading `no-action:` marker line the step-3 idempotency check parses. (The `--promoted-to` path posts only the numeric `promoted to #<M>`, so it carries no free text and needs no `--body-file`.)
   - Close: `gh issue close <issue-#> --reason "not planned"` (the **space** form — `gh` accepts only `{completed|not planned|duplicate}` and rejects the underscore `not_planned`).

5. **Audit log** — `audit_log info discussion-resolve created "discussion: #<issue-#> path=<promoted|no-action> [target=#<M>]"`.

6. **Output**:
   ```
   Resolved Discussion #<issue-#> via <promoted|no-action>.
   ```

## Operating mode

Same in attended and unattended.

## Escape

The `trusted-filer-mutate` hook's discussion-close arm blocks bare `gh issue close` on a `discussion` Issue. This skill is the canonical bypass — its close commands carry `--reason completed`/`--reason "not planned"` which the hook explicitly allows. No `SKIP_HOOKS` needed.

## Forbidden

- Closing without `--promoted-to <M>` OR `--no-action "<reason>"`.
- Closing with a third close-reason (e.g., `--reason duplicate`) — SPEC §5.19 names exactly two paths.
- Skipping the close comment — the comment is the parser-facing convention for downstream tools (`/triage`, `/audit`).
