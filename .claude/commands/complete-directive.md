---
description: Mark a Directive Completed — directive-reviewer evaluates evidence from linked Execution Issues (SPEC §2.1, §5.13). Reviewer can block if evidence is insufficient.
argument-hint: <directive-id>
---

Mark a Directive as `Status=Completed`. Requires `directive-reviewer` evaluation of success-signal satisfaction by linked Execution Issues.

## Procedure

1. **Resolve the Project** — same as `/file-directive` step 1.

2. **Resolve the Directive Issue** — `<directive-id>` is the GitHub Issue # for an activated Directive. Fetch:
   ```bash
   gh issue view <directive-id> --json title,body,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<directive-id> is not a Directive (`directive` label missing)") and stop.

3. **Collect linked Execution Issues** — search the repo for Issues whose body contains `^Parent Directive: #<directive-id>$`:
   ```bash
   gh issue list --search "in:body \"Parent Directive: #<directive-id>\"" --state all --json number,title,state,body,closedAt --limit 100
   ```
   - For each linked Issue: parse its AC ticks (`^- \[(x|~| )\] ` lines from the body) and its open/closed state.

4. **Read the Directive's success signals** from its body (the `## Success signals` section authored at `/file-directive` time).

5. **Reviewer gate** — invoke `directive-reviewer` (SPEC §4.9) on the completion claim. Pass:
   - The Directive body (with success signals as written).
   - The list of linked Execution Issues + their states + AC ticks.

   Parse the verdict per `/file-directive` step 4 dispatch.

   On `block` (evidence insufficient): stop. Status stays `Active`. Audit `directive-complete blocked "<reason>"`. Surface the verdict reason to the user.

6. **Flip Status to Completed**:
   - Find the Project Item that wraps Issue `<directive-id>`.
   - `gh project item-edit --id <item-id> --field-id <Status-field-id> --single-select-option-id <Completed-option-id>`.

7. **Post a closing comment** on the Directive Issue listing each success signal and its evidence:
   ```markdown
   ## Directive Completion (resolved by directive-reviewer ship verdict)

   - **Signal 1**: <signal text> — Evidence: PR #M (closed); AC #X ticked. Status: ✓
   - **Signal 2**: <signal text> — Evidence: PR #Y, #Z; smoke §N passes. Status: ✓
   - **Signal 3**: <signal text> — Evidence: <…>. Status: ✓
   - …

   Closed via /complete-directive.
   ```

8. **Close the Directive Issue** — `gh issue close <directive-id> --reason completed` after posting the comment.

9. **Audit log** — `audit_log info directive-complete completed "directive: #<directive-id> linked-execs=<N>"`.

10. **Output**:
    ```
    Completed Directive #<directive-id>: <Title>
    Status: Completed
    Evidence: <N> linked Execution Issues; all success signals satisfied.
    ```

## Operating mode

- **attended**: step 5's verdict surfaces to the user before flipping Status.
- **unattended**: step 5's verdict gates directly; `block` leaves Status=Active.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /complete-directive <id>` bypasses the reviewer (SPEC §2.1, §7). The bypass is audit-logged. Use is reserved for cases where the reviewer's verdict is wrong and a human accepts the recorded responsibility — not a normalized routing.

## Forbidden

- Marking a Directive `Completed` without a `directive-reviewer` ship verdict (or an audit-logged `SKIP_HOOKS=directive-review` escape).
- Closing the Issue without first flipping the Status field — closing-without-Completed creates a Project-vs-Issue state mismatch.
- Closing without the closing comment (step 7) — the comment is the canonical evidence record.
