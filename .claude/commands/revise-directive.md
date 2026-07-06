---
description: Revise an Active Directive Issue's body — archives prior body as a comment, reviewer-gates the new body, replaces the Issue body (no Status flip; the audit log + archive comment ARE the revision evidence).
argument-hint: <issue-#>
---

Replace an `Active` Directive Issue's body with a new one when scope or success signals changed. The prior body is preserved as a comment for history; the new body is reviewer-gated. No transient Status state — the audit-log entry + the archive comment ARE the revision evidence.

Issues are SSOT. The Project Item is unchanged by this command (body content isn't mirrored to Project fields).

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Resolve the Issue** — `<issue-#>` is a GitHub Issue number. Fetch:
   ```bash
   gh issue view <issue-#> --json title,body,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<N> is not a Directive (`directive` label missing)") and stop.
   - If `status:proposed` label present: error ("Directive is Proposed; revise the body via `gh issue edit` directly until activation") and stop. (Proposed Directives haven't been reviewer-vetted yet; activation is the first reviewer gate. Revising a Proposed Directive without re-activation is a contract gap — file a new `/activate` invocation after the body edit instead.)
   - If `status:blocked` label present: error ("Directive is Blocked; unblock via `/activate` first — that command re-runs the reviewer on the current body") and stop.

2. **Author the new body** — the user supplies the replacement body (full content per `.claude/templates/directive.md`: Objective / Success signals / Non-goals / Constraints / MISSION fit). Refuse to proceed if any required section is missing.

3. **Reviewer gate** — invoke `activation-reviewer` (SPEC §4.9) on the **new** body. Pass: proposed new body, list of currently Active Directives (filter out this one — it's about to change), MISSION.md content. Parse the verdict per `/file-directive` step 2 dispatch.

   - **`pass`** → proceed to step 4.
   - **`revise: <feedback>`** → revise the proposed new body per the one-line feedback. Re-invoke. The reviewer self-escalates to `reject` after N=3 `revise` markers (`.claude/agents/activation-reviewer.md`); on that `reject`, escalate (attended) or abort the body replacement (unattended).
   - **`reject: <reason>`** → stop. Leave the Issue body unchanged. Audit `directive-revise blocked "<reason>"`. No archive comment, no `reconciled` audit line.

4. **Compute the prior-body sha** — `shasum -a 256 <prior-body-file> | awk '{print $1}'`. Retain across step 5-7.

5. **Archive the prior body** — post a comment on the Directive Issue:
   ```markdown
   ## Pre-revision body — archived <YYYY-MM-DD>

   <verbatim prior body>

   *Replaced via /revise-directive. New body follows in the Issue description.*
   ```
   Use `gh issue comment <issue-#> --body-file <file>`. Capture the comment URL for audit.

6. **Replace the Issue body** — `gh issue edit <issue-#> --body-file <new-body-file>`.

7. **Audit log** — `audit_log info directive-revise reconciled "directive: #<issue-#> from-sha=<prior-body-sha256> archive-comment=<comment-url>"`. The sha lets a future investigator correlate the archived comment with the replaced body bytes.

8. **Mirror sync** — the mirror workflow fires on `issues.edited` and re-syncs whatever fields are derived from body content (today: Parent, derived from line-1 `Parent Directive: #N` marker — unchanged in a typical Directive revision).

9. **Output**:
   ```
   Revised Directive #<issue-#>: <Title>
   Prior body archived in comment: <comment-url>
   Status: unchanged (the audit log + archive comment ARE the revision evidence)
   ```

## Operating mode

- **attended**: step 3's verdict surfaces to the user before applying.
- **unattended**: step 3's verdict gates directly; `reject` leaves body unchanged.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /revise-directive <issue-#>` bypasses the reviewer. This escape is **command-prose-enforced** — no PreToolUse hook reads `directive-review`, so `should_skip` never auto-logs it. To keep the escape audit-logged (SPEC §7 escape contract), on taking the bypass **emit the record yourself**: run `. ".claude/ghjig-root/.claude/hooks/hookrt.sh"` then `audit_log escape directive-review skip "<why>"` (parity with the `should_skip` `SKIP_HOOKS` escape audit).

## Forbidden

- Revising a Directive whose label state is not Active (`status:proposed` or `status:blocked` Issues route differently).
- Replacing the body without posting the archive comment.
- Replacing the body before the reviewer's `pass` verdict.
- Re-introducing a transient `Revised` state — the audit log + archive comment ARE the evidence.
