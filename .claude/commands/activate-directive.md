---
description: Promote a Planned Directive to Active — converts the Draft Item to a real Issue, reviewer-gated (SPEC §2.1, §5.12).
argument-hint: <directive-id>
---

Transition a Directive from `Status=Planned` to `Status=Active` by promoting the Project Draft Item to a real GitHub Issue. Reviewer-gated.

## Procedure

1. **Resolve the Project** — same as `/file-directive` step 1.

2. **Resolve the Draft Item** — `<directive-id>` is the Project Item ID from `/file-directive`'s output. Fetch the item:
   ```bash
   gh project item-list <project-num> --owner <owner> --format json --limit 100 \
     | jq --arg id "<directive-id>" '.items[] | select(.id==$id)'
   ```
   - If not found: print error and stop.
   - If `Type != Directive`: print error ("Item is not a Directive — `Type=<X>`") and stop.
   - If `Status != Planned`: print error ("Directive is already `Status=<X>` — use /complete-directive or /list-directives to inspect") and stop.

3. **Reviewer gate** — re-invoke `directive-reviewer` (SPEC §4.9) on the (possibly edited since draft) body. The body may have changed in the GH UI since the original `/file-directive` invocation; the reviewer re-validates schema, scope, and active-Directive conflict against the current state. Parse verdict per `/file-directive` step 4 dispatch.

   On `block`: stop. Status stays `Planned`. Audit `directive-activate blocked "<reason>"`.

4. **Promote to a real Issue**:
   - Read the Draft Item's title + body.
   - Ensure the `directive` label exists on the repo (`gh label create directive` if missing; idempotent).
   - Create the Issue:
     ```bash
     gh issue create --title "<Title>" --body "<Body + 'Filed by /activate-directive from Project Item <directive-id>'>" --label "directive"
     ```
   - Capture the new Issue number `<N>`.

5. **Link the Issue back to the Project Item** — `gh project item-add <project-num> --owner <owner> --url <issue-url>`. This adds the Issue as a new Project Item; the original Draft Item becomes redundant. Archive the Draft via `gh project item-archive --id <directive-id>` to preserve history without cluttering the view.

6. **Set custom fields** on the new Issue-backed Item:
   - `Type=Directive` (preserved)
   - `Status=Active` (changed from Planned)
   - `Priority`, `Confidence`, `Success Signals`, `Parent` — copied from the archived Draft Item.

7. **Audit log** — `audit_log info directive-activate created "directive: #<N> from-draft=<directive-id>"`.

8. **Output**:
   ```
   Activated Directive #<N>: <Title>
   Status: Active
   The original Draft Item <directive-id> is archived.
   Next: file Execution Issues against this Directive with /file-issue --parent <N>.
   ```

## Operating mode

- **attended**: step 3's verdict surfaces to the user before activation.
- **unattended**: step 3's verdict gates directly.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /activate-directive <id>` bypasses the reviewer. Audit-logged.

## Forbidden

- Activating a Directive that is `Status != Planned`.
- Activating an Item whose `Type != Directive`.
- Creating the real Issue without the `directive` label — that label is the engineering hook's signal (SPEC §6.1 `directive-protect` matcher) that `/work-on <N>` should refuse.
