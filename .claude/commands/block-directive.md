---
description: Mark an Active Directive as Blocked — posts a ## Blocked comment, flips Project Status=Blocked, keeps the Issue open (SPEC §2.1, §5.17).
argument-hint: <directive-id> --reason <why>
---

Mark an `Active` Directive as `Status=Blocked` when it cannot proceed without external input. The Issue stays open; only the Project `Status` field reflects the block. Unblock by running `/activate-directive` on the Issue — that command re-invokes `directive-reviewer` on the current body and on `ship` flips `Status` back to `Active`.

Not reviewer-gated by `directive-reviewer` — blocking is an annotation, not a body change.

## Procedure

1. **Parse arguments** — `<directive-id>` is the GitHub Issue # for an activated Directive; `--reason <why>` is **mandatory**. If `--reason` is missing or its value is empty after whitespace-trim: error ("--reason <why> is required for /block-directive") and stop.

2. **Resolve the Project** — same as `/file-directive` step 1.

3. **Resolve the Directive Issue** — fetch:
   ```bash
   gh issue view <directive-id> --json title,body,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<directive-id> is not a Directive (`directive` label missing)") and stop.
   - If the Project Item's `Status != Active`: error ("Directive is already `Status=<X>`") and stop. (Blocking a `Planned` Draft Item is nonsensical; blocking a `Completed` Directive is nonsensical; blocking an already-`Blocked` Directive is a no-op handled by the idempotency check in step 4.)

4. **Idempotency check** — read the Directive's recent comments (most-recent 10 suffices). If the latest comment matches the regex `^## Blocked: ` AND the Project `Status` is already `Blocked`, the block is already in place. Emit:
   ```
   /block-directive: already blocked (idempotent no-op)
   ```
   `audit_log info directive-block skipped "already-blocked: directive=#<directive-id>"`. Stop.

5. **Post the block comment** — `gh issue comment <directive-id> --body "## Blocked: <reason>"`. Capture the comment URL for audit.

6. **Flip Status to Blocked** — find the Project Item that wraps Issue `<directive-id>`, then:
   ```bash
   gh project item-edit --id <item-id> --project-id <proj-id> --field-id <Status-field-id> --single-select-option-id <Blocked-option-id>
   ```

7. **Audit log** — `audit_log info directive-block created "directive: #<directive-id> reason=<short> comment=<comment-url>"`. Truncate `reason` to ~60 chars for the audit line; the full text is in the comment.

8. **Output**:
   ```
   Blocked Directive #<directive-id>: <Title>
   Reason: <reason>
   Block comment: <comment-url>
   Status: Blocked
   To unblock: /activate-directive <directive-id> (re-runs directive-reviewer on the current body)
   ```

## Operating mode

Same in attended and unattended — no reviewer gate, no operating-mode-dependent branch.

## Escape

`/block-directive` is not reviewer-gated. There is no `SKIP_HOOKS=directive-review` variant — the command does not invoke `directive-reviewer`. If the block itself is misguided, unblock via `/activate-directive` (which re-runs the reviewer on the current body and on `ship` returns `Status` to `Active`).

## Forbidden

- Blocking without `--reason <why>` — the reason is the canonical artifact for the block; absent it, the audit trail loses the "why."
- Blocking a Directive whose `Status` is `Planned`, `Completed`, or `Revised` (transient). `Planned` Directives are filed but not yet activated — block makes no sense. `Completed` are immutable. `Revised` is transient — wait for it to return to `Active`.
- Closing the Directive Issue on block. The Issue stays open; only the Project `Status` field reflects `Blocked`. Closing requires `/complete-directive` (SPEC §5.13).
- Posting more than one `## Blocked: ...` comment in a row (idempotency check at step 4). A second block needs a new reason that supersedes the first — file an additional `## Blocked (revised): <new-reason>` comment manually or use `/revise-directive` if the Objective itself changed.
