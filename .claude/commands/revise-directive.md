---
description: Revise an Active Directive's body — archives prior body as a comment, reviewer-gates the new body, transient Status=Revised → back to Active (SPEC §2.1, §5.16).
argument-hint: <directive-id>
---

Replace an `Active` Directive Issue's body with a new one when scope or success signals changed. The prior body is preserved as a comment for history; the new body is reviewer-gated. Project `Status` flips to `Revised` as an audit beat, then returns to `Active` so the Directive remains workable.

## Procedure

1. **Resolve the Project** — same as `/file-directive` step 1.

2. **Resolve the Directive Issue** — `<directive-id>` is the GitHub Issue # for an activated Directive. Fetch:
   ```bash
   gh issue view <directive-id> --json title,body,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<directive-id> is not a Directive (`directive` label missing)") and stop.
   - If the Project Item's `Status != Active` (and not `Blocked` — see Forbidden below for the Blocked path): error and stop.

3. **Author the new body** — the user supplies the replacement body (full content, including `## Objective` / `## Success signals` / `## Non-goals` / `## Constraints` / `## Parent Goal` sections per `.claude/templates/directive.md`). Refuse to proceed if the new body is missing any required section.

4. **Reviewer gate** — invoke `directive-reviewer` (SPEC §4.9) on the **new** body. Pass: proposed new body, list of currently `Status=Active` Directives (filter out the Directive being revised — it's about to change), parent Goal reference. Parse the verdict per `/file-directive` step 4 dispatch.

   - **`ship`** → proceed to step 5.
   - **`refine: <feedback>`** → revise the proposed new body per the one-line feedback. Re-invoke `directive-reviewer` on the revised body. After two consecutive `refine` verdicts on the latest body, escalate to the user (attended) or treat as `block` (unattended).
   - **`block: <reason>`** → stop. Leave the Issue body and Status unchanged. Audit `directive-revise blocked "<reason>"`. No archive comment, no audit `reconciled` line. Status stays `Active`.

5. **Archive the prior body** — post a comment on the Directive Issue:
   ```markdown
   ## Pre-revision body — archived <YYYY-MM-DD>

   <verbatim prior body>

   *Replaced via /revise-directive. New body follows in the Issue description.*
   ```
   Use `gh issue comment <directive-id> --body-file <file>`. Capture the comment URL for audit.

6. **Replace the Issue body** — `gh issue edit <directive-id> --body-file <new-body-file>`.

7. **Flip Status to Revised, then back to Active** — find the Project Item that wraps Issue `<directive-id>`, then:
   ```bash
   gh project item-edit --id <item-id> --project-id <proj-id> --field-id <Status-field-id> --single-select-option-id <Revised-option-id>
   gh project item-edit --id <item-id> --project-id <proj-id> --field-id <Status-field-id> --single-select-option-id <Active-option-id>
   ```
   The transient `Revised` state matters for the audit trail and `/list-directives --status=Revised` introspection; it should not be observed as a long-lived state.

8. **Audit log** — `audit_log info directive-revise reconciled "directive: #<directive-id> from-sha=<prior-body-sha256> archive-comment=<comment-url>"`. The prior-body sha lets a future investigator correlate the archived comment with the replaced body bytes.

9. **Output**:
   ```
   Revised Directive #<directive-id>: <Title>
   Prior body archived in comment: <comment-url>
   Status: Active (transitioned Active → Revised → Active)
   ```

## Operating mode

- **attended**: step 4's verdict surfaces to the user before applying the revision.
- **unattended**: step 4's verdict gates directly; `block` leaves the body unchanged.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /revise-directive <id>` bypasses the reviewer (SPEC §2.1, §7). Audit-logged. Reserved for cases where the reviewer's verdict is wrong and a human accepts the recorded responsibility — not a normalized routing. The archive comment + body replacement still fire.

## Forbidden

- Revising a Directive whose Project `Status != Active`. A `Blocked` Directive must be unblocked via `/activate-directive` first (which re-runs the reviewer); a `Completed` Directive is immutable (file a new Directive instead).
- Replacing the body without posting the archive comment — the comment is the canonical history of the prior version.
- Replacing the body before the reviewer's `ship` verdict — the gate exists to prevent low-quality revisions from silently overwriting reviewer-vetted contracts.
- Leaving `Status=Revised` as the final state — the field must return to `Active` at the end of the flow (Forbidden by the transient-state contract in SPEC §2.1 / §5.16).
