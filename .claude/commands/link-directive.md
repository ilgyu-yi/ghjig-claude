---
description: Link an Execution Issue to its parent Directive (SPEC §5.14). Idempotent.
argument-hint: <directive-id> <issue-#>
---

Explicitly link an Execution Issue to its parent Directive. Sets the Issue's Project `Parent` field and posts cross-reference comments on both items.

## Procedure

1. **Resolve the Project** — same as `/file-directive` step 1.

2. **Validate the two arguments**:
   - `<directive-id>` — must be a `directive`-labeled, OPEN Issue. Fetch via `gh issue view`. If not a Directive: stop.
   - `<issue-#>` — must be an Issue WITHOUT the `directive` label (i.e., an Execution Issue). If it is itself a Directive: stop with error ("Cannot parent a Directive under another Directive in v0 — see SPEC §0.4 directive-graph deferral").

3. **Idempotency check** — read the Execution Issue's body. If it already contains `Parent Directive: #<directive-id>` at the start of a line, AND its Project Item has `Parent=#<directive-id>`, the link is already in place. Emit:
   ```
   /link-directive: already linked (idempotent no-op)
   ```
   `audit_log info directive-link skipped "already-linked: directive=#<directive-id> issue=#<issue-#>"`.

   Otherwise proceed to steps 4-6.

4. **Update the Issue body** — prepend the marker `Parent Directive: #<directive-id>` as the first line of the body (or directly under any existing `Closes #N` / `Refs #N` trailer at the top). Use `gh issue edit <issue-#> --body-file <new-body>`.

5. **Update the Project field** — find the Project Item that wraps Issue `<issue-#>` and edit its `Parent` text field:
   ```bash
   gh project item-edit --id <item-id> --field-id <Parent-field-id> --text "#<directive-id>"
   ```

6. **Post cross-reference comments** — on Issue `<issue-#>`: `Parent Directive: #<directive-id>`. On Issue `<directive-id>`: `Linked Execution: #<issue-#>`. Use `gh issue comment` for both. Skip a comment if the same marker already appears in the issue's recent comments (idempotency).

7. **Audit log** — `audit_log info directive-link created "directive=#<directive-id> issue=#<issue-#>"`.

8. **Output**:
   ```
   Linked Execution #<issue-#> under Directive #<directive-id>.
   ```

## Operating mode

Same in attended and unattended.

## Forbidden

- Linking two Directives (v0 non-goal — directive dependency graph is v1+).
- Overwriting an existing different `Parent Directive: #<other>` marker without explicit user confirmation. If the Issue is already linked to a *different* Directive, stop and report rather than silently re-parenting.
- Skipping the body-marker step — the regex `^Parent Directive: #(\d+)$` is consumed by `/reflect` and `/ship` (SPEC §5.2 / §5.7 integrations from PR #47).
