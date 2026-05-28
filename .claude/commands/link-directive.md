---
description: Link an Execution Issue to its parent Directive — sets the `Parent Directive: #N` body marker. Idempotent.
argument-hint: <directive-#> <execution-#>
---

Link an Execution Issue to its parent Directive by ensuring the `Parent Directive: #<N>` line-1 body marker is set + posting cross-reference comments. The Project Item's `Parent` field is mirrored from this body marker by `.github/workflows/issues-to-project-mirror.yml` — `/link-directive` does NOT write to the Project directly.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Validate the two arguments**:
   - `<directive-#>` — must be a `directive`-labeled, OPEN Issue. Fetch via `gh issue view`. If not a Directive: stop.
   - `<execution-#>` — must be an Issue WITHOUT the `directive` label (i.e., an Execution Issue or Task / Bug). If it is itself a Directive: stop with error ("Cannot parent a Directive under another Directive — directive dependency graph is deferred per SPEC §0.4").

2. **Idempotency check** — read the Execution Issue's body. If line 1 already matches `^Parent Directive: #<directive-#>$`, the link is already in place. Emit:
   ```
   /link-directive: already linked (idempotent no-op)
   ```
   `audit_log info directive-link skipped "already-linked: directive=#<directive-#> issue=#<execution-#>"`. Stop.

3. **Update the Issue body** — prepend the marker `Parent Directive: #<directive-#>` as the first line of the body. Use `gh issue edit <execution-#> --body-file <new-body>`.

4. **Post cross-reference comments**:
   - On Issue `<execution-#>`: `Parent Directive: #<directive-#>` (skip if same marker already in recent comments).
   - On Issue `<directive-#>`: `Linked Execution: #<execution-#>` (skip if same marker already in recent comments).

5. **Audit log** — `audit_log info directive-link created "directive=#<directive-#> issue=#<execution-#>"`.

6. **Mirror sync** — the mirror workflow fires on `issues.edited` and updates the Project Item's `Parent` field from the new body marker. `/link-directive` does NOT wait for the mirror.

7. **Output**:
   ```
   Linked Execution #<execution-#> under Directive #<directive-#>.
   ```

## Operating mode

Same in attended and unattended.

## Forbidden

- Linking two Directives (v0 non-goal — directive dependency graph deferred per SPEC §0.4).
- Overwriting an existing different `Parent Directive: #<other>` marker without explicit user confirmation. If the Issue is already linked to a *different* Directive, stop and report rather than silently re-parenting.
- Skipping the body-marker step — the regex `^Parent Directive: #(\d+)$` is consumed by `/reflect`, the dir-mode-post-merge workflow, AND the issues-to-project-mirror workflow (SPEC §5.2, §5.7).
- Writing to the Project Item's `Parent` field directly — that's the mirror workflow's job.
