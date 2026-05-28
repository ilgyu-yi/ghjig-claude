---
description: File a new Directive as a GitHub Issue with `directive` + `status:proposed` labels (dir-mode v3 — Issues-as-SSOT per ADR-0003 / Directive #92). Reviewer-gated.
argument-hint: ""
---

Create a new Directive as a GitHub Issue. Body authored from `.claude/templates/directive.md`. Reviewer-gated before `gh issue create`.

In dir-mode v3 (ADR-0003), **Issues are SSOT**. The Project Item that wraps the new Issue is created and populated by `.github/workflows/issues-to-project-mirror.yml` (cluster D mirror workflow) — `/file-directive` does NOT write to the Project directly.

## Procedure

0. **Step 0 — substrate preflight** (ADR-0004; #118): verify the target satisfies this command's tier requirement. Tier 2 minimum for all dir-mode commands (10-label v3 set must exist). If `gh label list | grep -qx directive` fails, exit with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"`. Fail-open on `gh` network errors per ADR-0004 reversibility framing.

1. **Author the body** from `.claude/templates/directive.md`:
   - **Objective** — bounded by concrete artifact-level boundary (issue counts, file paths, AC ticks, merge events). Refuse to proceed if the Objective doesn't name a concrete artifact-level boundary.
   - **Success signals** — 2 to 5 verifiable conditions. Each must be objectively testable by a reasonable engineer.
   - **Non-goals** — at least 2 explicit exclusions.
   - **Constraints** — at least 1 invariant to preserve.
   - **MISSION fit** — which `MISSION.md` section or success criterion does this Directive serve? (Replaces the v0/v1 `Parent Goal` field per ADR-0003 Decision 6.)
   - **Priority** — one of `P0` / `P1` / `P2` / `P3`; ask the user. Defaults to `P2` in unattended mode if not specified. The matching label is applied to the Issue at create time.
   - **Confidence** — 0-100; ask the user.

2. **Reviewer gate** — invoke the `directive-reviewer` subagent (SPEC §4.9) on the proposed body. Pass: proposed body, list of currently `Active` Directives (`gh issue list --label directive --label '-status:proposed' --state open --json number,title,body --limit 100`), MISSION.md content. Parse the verdict line.

   Verdict dispatch (SPEC §2.1, §5.7.1 operating-mode coupling):
   - **`ship`** → proceed to step 3.
   - **`refine: <feedback>`** → revise the body per the one-line feedback. Re-invoke `directive-reviewer` on the revised body. After two consecutive `refine` verdicts, escalate to the user (attended) or treat as `block` (unattended).
   - **`block: <reason>`** → do NOT create the Issue. In attended mode: report the reason and stop. In unattended mode: append one line to `$CLAUDE_ENG_SHELL_ROOT/.claude/state/directive-block.log` and stop.

3. **Create the Issue**:
   ```bash
   gh issue create \
     --title "directive: <Objective summary, ≤80 chars>" \
     --body "<full body from step 1>" \
     --label "directive" \
     --label "status:proposed" \
     --label "P<P>"
   ```
   Capture the new Issue number `<N>`. The `P<P>` label (one of `P0`/`P1`/`P2`/`P3`) is the priority captured in step 1; the mirror workflow reads this label to populate the Project Item's Priority field.

4. **Audit log** — `audit_log info directive-file created "directive: <Objective summary> issue=#<N> priority=P<P> confidence=<C>"`.

   Both `<P>` and `<C>` are populated from the step-1 collection — emitting them with the placeholder literal (`priority=P<P>`) drops the format-validation contract in `.claude/hooks/hookrt.sh:_audit_validate_format` and produces a `directive-file/format-error` warn entry instead of the requested `created` record. Use the captured values.

   The `issue=#<id>` token replaces the v0/v1 `item=<PVTI-id>` token (Issues are SSOT now per ADR-0003).

5. **Mirror sync** — the `issues-to-project-mirror.yml` workflow fires on `issues.opened` and populates the Project Item's fields. `/file-directive` does NOT wait for the mirror; it returns immediately after the audit line.

6. **Output**:
   ```
   Filed Directive Issue #<N>: <Objective summary>
   Status: Proposed (label: status:proposed)
   Next: /activate-directive <N> when ready (re-runs reviewer; removes status:proposed → Active).
   ```

## Operating mode

- **attended** (default): step 2 surfaces the verdict to the user before applying.
- **unattended**: step 2's verdict gates directly.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /file-directive` bypasses the reviewer gate. Audit-logged.

## Forbidden

- Creating an Issue with an empty or stub-only Objective.
- Skipping the reviewer gate without `SKIP_HOOKS=directive-review`.
- Writing directly to the Project Item — that's the mirror workflow's job.
- Setting the `directive` label without `status:proposed` — Proposed is the first state for any new Directive.
