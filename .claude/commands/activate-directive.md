---
description: Activate a Proposed Directive — re-runs directive-reviewer; on `ship` removes the `status:proposed` label (Issue → Active).
argument-hint: <issue-#>
---

Transition a Directive from `Status=Proposed` to `Status=Active` by removing the `status:proposed` label after a fresh `directive-reviewer` pass on the current body (which may have been edited in the GH UI since filing).

Status is encoded as labels on the Issue (Issues are SSOT). Project Status field is mirrored by `.github/workflows/issues-to-project-mirror.yml`. `/activate-directive` does NOT write to the Project directly.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Resolve the Issue** — `<issue-#>` is a GitHub Issue number. Fetch:
   ```bash
   gh issue view <issue-#> --json title,body,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<N> is not a Directive (`directive` label missing)") and stop.
   - If `status:proposed` label absent: error ("Directive is already Active (no `status:proposed` label). Use `/list-directives` to inspect.") and stop.

2. **Reviewer gate** — re-invoke `directive-reviewer` (SPEC §4.9) on the current body. The body may have changed in the GH UI since filing; the reviewer re-validates schema, scope, and active-Directive conflict against the current state. Parse verdict per `/file-directive` step 2 dispatch.

   On `block`: stop. `status:proposed` label stays. Audit `directive-activate blocked "<reason>"`.

3. **Remove the `status:proposed` label**:
   ```bash
   gh issue edit <issue-#> --remove-label "status:proposed"
   ```
   The Issue is now `Active` (open + `directive` label + no status label).

4. **Audit log** — `audit_log info directive-activate created "directive: #<issue-#> ratified from-sha=<body-sha256>"`.

5. **Mirror sync** — the mirror workflow fires on `issues.unlabeled` and updates the Project Item's Status field from Proposed to Active.

6. **Output**:
   ```
   Activated Directive #<issue-#>: <Title>
   Status: Active (status:proposed label removed)
   Next: file Execution Issues against this Directive with /file-issue --parent <issue-#>.
   ```

## Operating mode

- **attended**: step 2's verdict surfaces to the user before activation.
- **unattended**: step 2's verdict gates directly.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /activate-directive <issue-#>` bypasses the reviewer. Audit-logged.

## Forbidden

- Activating an Issue without the `directive` label.
- Activating an Issue without the `status:proposed` label (not in Proposed state).
- Writing to the Project Item directly — that's the mirror workflow's job.
