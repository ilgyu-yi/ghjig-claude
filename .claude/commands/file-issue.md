---
description: Create a GitHub issue. Enforces MISSION reference and acceptance criteria. Supports --parent <directive-id> to parent the new Execution Issue under an active Directive (SPEC §5.2 dir-mode integration).
argument-hint: [--quick] [--parent <directive-id>|--no-parent] <description>
---

Create an issue.

1. Parse `$ARGUMENTS`:
   - With `--quick`: one-line issue (label `bug`), ask only for one acceptance criterion. (`bug` matches the `bug-report.yml` Issue Form template label.)
   - With `--parent <directive-id>`: parent this Issue under the named Directive (SPEC §5.2 dir-mode integration). The Directive's number is the value passed to the flag — e.g., `/file-issue --parent 91 fix-the-thing`.
   - With `--no-parent`: explicitly opt out of parenting (skip step 1.5).
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
5. **Derive the type label deterministically** (SPEC §1.7 line 309 — the label *is* the type; never agent discretion):
   - `--quick` → **`bug`** (from step 1).
   - a parent Directive was selected in step 1.5 (via `--parent` or the prompt) → **`execution`** (a unit of work parented under a Directive).
   - otherwise — standalone (`--no-parent`, no active Directives, the prompt answered "none", or unattended with no `--parent`) → **`task`**.

   These three values match the Issue-Form template labels (`bug-report.yml` / `execution-under-directive.yml` / `task.yml`) so skill-path and UI-path filings classify identically. Then call `gh issue create --title "..." --body "..." --label "<derived: bug|execution|task>" --label "status:proposed"`. **Full-symmetry stamp (#172, SPEC §2.1/§5.2):** every new Issue is filed `status:proposed` and must pass `/activate <N>` before it is actionable. `issue-reviewer` here is author-side; `activation-reviewer` at `/activate` is observer-side — complementary, not redundant. (If the target lacks the `status:proposed` label — tier &lt; 2 — omit the label and note it; the lifecycle gate is a tier-2 capability.)
6. Output the created issue number and URL, with a `Next: /activate <N>` line. Do NOT `/work-on <N>` before activation — `proposed-protect` (SPEC §6.1) blocks branch creation against a `status:proposed` Issue.

**Forbidden**: creating an issue with empty or ambiguous acceptance criteria, with a weak rationale that didn't pass the §3 check, OR with a non-`ship` verdict from `issue-reviewer`. If unclear, re-ask the user and stop.
