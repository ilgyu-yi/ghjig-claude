---
description: Create a GitHub issue. Enforces MISSION reference, acceptance criteria, and a priority (P0–P3). Supports --parent <directive-id> to parent the new Execution Issue under an active Directive (SPEC §5.2 dir-mode integration).
argument-hint: [--quick] [--parent <directive-id>|--no-parent] [--priority P0|P1|P2|P3] <description>
---

Create an issue.

1. Parse `$ARGUMENTS`:
   - With `--quick`: one-line issue (label `bug`), ask only for one acceptance criterion. (`bug` matches the `bug-report.yml` Issue Form template label.)
   - With `--parent <directive-id>`: parent this Issue under the named Directive (SPEC §5.2 dir-mode integration). The Directive's number is the value passed to the flag — e.g., `/file-issue --parent 91 fix-the-thing`.
   - With `--no-parent`: explicitly opt out of parenting (skip step 1.5).
   - With `--priority P0|P1|P2|P3`: set the priority explicitly (skips the step-1.6 prompt).
   - Otherwise: confirm title, body, label with the user.
1.5. **Directive parenting** (added by tracking #41 child #6; SPEC §5.2 dir-mode integration) — runs unless `--no-parent` or `--quick` was passed:
   - Resolve the dir-mode Project (see `/file-directive` step 1).
   - List currently `Status=Active` Directives in the Project (`gh issue list --label directive --state open --json number,title --limit 100`).
   - If at least one active Directive exists AND `--parent` was not provided, prompt the user:
     ```
     Active Directives:
       #91  Stabilize v0 director-mode
       #105 Improve documentation coverage
     Parent this Issue to a Directive? Enter number, or "none": _
     ```
     The user picks a number or types `none`. Empty / invalid input falls back to "none" with a stderr note.
     - **Unattended mode**: there is no user to prompt — do **NOT** auto-parent. Default to `none` (standalone) unless `--parent <id>` was explicit. Auto-selecting a Directive here is the regression that mislabels a standalone `task` as a parented `execution` (SPEC §5.2 / §1.7 line 309); `--parent` is the *only* parenting signal in unattended mode (`--no-parent` is then redundant but harmless).
   - If a parent Directive is selected (via flag or prompt):
     - Set `parent_directive=<N>`.
     - Prepend `Parent Directive: #<N>` as the first line of the body (above `Closes #` / `Refs #` if present), so `/reflect` and `/ship` (steps 10.5 below) can find it via the canonical regex `^Parent Directive: #(\d+)$`.
     - After `gh issue create` succeeds (step 5), update the new Issue's Project `Parent` field via `/link-directive <N> <new-issue#>` (idempotent, audit-logs `directive-link`).
   - If no active Directives exist OR the user picked "none": skip this step. No body change, no Project parenting.

   This step is **metadata only** — the rationale check (step 3) and `issue-reviewer` gate (step 4) are unchanged. Parenting is not part of the rationale triad.
1.6. **Priority** (#291; parity with `/file-directive`) — capture one of `P0` / `P1` / `P2` / `P3` so the Issue lands triageable, never priority-less:
   - If `--priority P<N>` was passed (step 1), use it.
   - Otherwise in **attended** mode, ask the user (`P0` drop-everything / `P1` next / `P2` soon / `P3` eventually).
   - In **unattended** mode with no `--priority`, default to **`P2`** (the same default `/file-directive` uses). Do not block on the absence of a human.
   - The chosen `P<N>` is applied as a label at create time (step 5, graceful-degradation guarded) **and** recorded in the step-5 audit line, so the priority survives even if the label can't be applied. For a `--parent`ed Execution Issue, this is still captured (an Execution Issue carries its own priority; it does not silently inherit the Directive's).
2. The body follows the structure of `$CLAUDE_ENG_SHELL_ROOT/.claude/templates/issue.md`. MISSION reference and acceptance criteria must be filled.
3. **Rationale check** (mandatory; not skipped in Auto / unattended mode). Before `gh issue create`, surface to the user:
   - **(a) MISSION fit**: which MISSION item does this serve?
   - **(b) Why now**: what changes if this waits a week / a quarter?
   - **(c) Existing-issue / open-PR coverage**: would a comment on an existing issue, or a follow-up note in an open PR, suffice instead?
   "Weak" means any of (a)–(c) cannot be answered in a sentence, or the answer reduces to "to be tidy" / "someday" / "while I'm in the area." If any of (a)–(c) is weak, refine the issue or drop the request instead of filing. This is a moment of reflection, not a form to fill.
4. **Reviewer gate** — invoke the `issue-reviewer` subagent (see SPEC §4.7) on the proposed body. Pass the body, the target MISSION.md, and the `gh issue list --state open --limit 100 --json number,title,body` snapshot. Parse the verdict line (`^VERDICT: (ship|refine|block)`).
   - **`ship`**: proceed to step 5.
   - **`refine: <feedback>`**: revise the body per the one-line feedback. Re-invoke `issue-reviewer` on the revised body. After two consecutive `refine` verdicts on the latest body, escalate to the user (or, in unattended mode, treat as `block`).
   - **`block: <reason>`**: do NOT call `gh issue create`. In attended mode: report the reason to the user and stop. In unattended mode: append one line to `$CLAUDE_ENG_SHELL_ROOT/.claude/state/issue-block.log` naming the rejected title and reason, then stop.
   - **Reject-audit emission** (SPEC §6.1, Directive #356 signal 3) — on **any** non-pass verdict (`refine` or `block`), emit one categorized audit record: source `hookrt.sh` + `safe_source helpers/reviewer_audit.sh reviewer-reject`, then `reviewer_reject_audit issue-review <reason-class> <issue-or-draft-id>`, mapping the reviewer's reason to the nearest **reason-class** token (`schema-incomplete` / `unverifiable-ac` / `scope-bleed` / `mission-misfit` / `conflict` / `evidence-insufficient`). This is observability only — it never changes the verdict's effect.
5. **Derive the type label deterministically** (SPEC §1.7 line 309 — the label *is* the type; never agent discretion):
   - `--quick` → **`bug`** (from step 1).
   - a parent Directive was selected in step 1.5 (via `--parent` or the prompt) → **`execution`** (a unit of work parented under a Directive).
   - otherwise — standalone (`--no-parent`, no active Directives, the prompt answered "none", or unattended with no `--parent`) → **`task`**.

   These three values match the Issue-Form template labels (`bug-report.yml` / `execution-under-directive.yml` / `task.yml`) so skill-path and UI-path filings classify identically. Then call `gh issue create` with the derived type label, `status:proposed`, **and the step-1.6 priority label** — the `P<N>` label is **graceful-degradation guarded** (parity with `/file-directive`): apply it only if it exists on the target, else warn and file without it (never abort):
   ```bash
   # P-label is degradable: apply if present, else warn + continue (never abort).
   PLABEL=()
   if gh label list --limit 200 | cut -f1 | grep -qx "P<N>"; then
     PLABEL=(--label "P<N>")
   else
     printf 'warn: priority label P<N> absent on target — filing without it (run scripts/ensure_v3_labels.sh to install P0-P3).\n' >&2
   fi
   gh issue create --title "..." --body "..." \
     --label "<derived: bug|execution|task>" --label "status:proposed" "${PLABEL[@]}"
   ```
   **Full-symmetry stamp (#172, SPEC §2.1/§5.2):** every new Issue is filed `status:proposed` and must pass `/activate <N>` before it is actionable. `issue-reviewer` here is author-side; `activation-reviewer` at `/activate` is observer-side — complementary, not redundant. (If the target lacks the `status:proposed` label — tier &lt; 2 — omit the label and note it; the lifecycle gate is a tier-2 capability.) After create, audit `audit_log info issue-file created "type=<bug|execution|task> issue=#<N> priority=P<N>"` so the priority is recorded even when the label was degraded away.
6. Output the created issue number and URL, with a `Next: /activate <N>` line. Do NOT `/work-on <N>` before activation — `proposed-protect` (SPEC §6.1) blocks branch creation against a `status:proposed` Issue.

**Forbidden**: creating an issue with empty or ambiguous acceptance criteria, with a weak rationale that didn't pass the §3 check, OR with a non-`ship` verdict from `issue-reviewer`. If unclear, re-ask the user and stop.

## Work language
Author the **issue body** (title, What / Why / Acceptance criteria, Notes) in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the task context into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`.
