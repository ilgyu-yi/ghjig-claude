---
description: Mark an Active Directive Issue as Blocked by adding the `status:blocked` label + a ## Blocked comment.
argument-hint: <issue-#> --reason <why>
---

Add the `status:blocked` label and a `## Blocked: <reason>` comment to an Active Directive Issue. The Issue stays open; the label drives the mirror workflow's Status=Blocked.

`status:blocked` is the canonical state encoding. The Project Item's Status field follows via `.github/workflows/issues-to-project-mirror.yml`.

Not reviewer-gated by `activation-reviewer` — blocking is an annotation, not a body change.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Parse arguments** — `<issue-#>` is the GitHub Issue number; `--reason <why>` is **mandatory**. If `--reason` is missing or its value is empty after whitespace-trim: error ("--reason <why> is required for /block-directive") and stop.

2. **Resolve the Issue** — fetch:
   ```bash
   gh issue view <issue-#> --json title,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<N> is not a Directive (`directive` label missing)") and stop.
   - If `status:proposed` label present: error ("Directive is Proposed; activate first via /activate") and stop.
   - If `status:blocked` label present: see step 3 idempotency.

3. **Idempotency check** — read the Issue's recent comments. If the latest comment matches the regex `^## Blocked: ` AND the `status:blocked` label is already present, the block is already in place. Emit:
   ```
   /block-directive: already blocked (idempotent no-op)
   ```
   `audit_log info directive-block skipped "already-blocked: directive=#<N>"`. Stop.

4. **Post the block comment** — write `## Blocked: <reason>` to a temp file and post via `gh issue comment <issue-#> --body-file <file>` (#504). Never inline `--body "## Blocked: <reason>"` — a backtick / `$(...)` / quote in the free-text reason would corrupt the comment or execute at assembly time; this mirrors the dir-mode `--body-file` bar (`/revise-directive`, `/consume-initiative`, `/activate` refile). Preserve the leading `## Blocked: ` marker line the step-3 idempotency check greps for. Capture the comment URL for audit.

5. **Add the `status:blocked` label**:
   ```bash
   gh issue edit <issue-#> --add-label "status:blocked"
   ```

6. **Audit log** — `audit_log info directive-block created "directive: #<issue-#> reason=<short> comment=<comment-url>"`. Truncate `reason` to ~60 chars for the audit line.

7. **Mirror sync** — the mirror workflow fires on `issues.labeled` and updates the Project Item's Status field to Blocked.

8. **Output**:
   ```
   Blocked Directive #<issue-#>: <Title>
   Reason: <reason>
   Block comment: <comment-url>
   Status: Blocked (label: status:blocked)
   To unblock: /activate <issue-#> (re-runs activation-reviewer; removes status:blocked label on a `pass` verdict).
   ```

## Operating mode

Same in attended and unattended — no reviewer gate, no operating-mode-dependent branch.

## Escape

`/block-directive` is not reviewer-gated. There is no `SKIP_HOOKS=directive-review` variant. If the block itself is misguided, unblock via `/activate` (re-runs the reviewer and on `pass` removes the `status:blocked` label; `/activate-directive` is a deprecated alias).

## Forbidden

- Blocking without `--reason <why>`.
- Blocking a Directive whose `directive` label is absent (not a Directive Issue) or whose `status:proposed` label is present (not yet Active).
- Closing the Directive Issue on block. The Issue stays open; the label drives Status. Closing requires `/complete-directive` (§5.13).
- Posting more than one `## Blocked: ...` comment in a row (idempotency at step 3).
- Writing to the Project Item directly — the mirror handles the Status field.
