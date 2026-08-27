---
description: File a new Directive as a GitHub Issue with `directive` + `status:proposed` labels. Reviewer-gated.
argument-hint: ""
---

Create a new Directive as a GitHub Issue. Body authored from `.claude/templates/directive.md`. Reviewer-gated before `gh issue create`.

**Issues are SSOT**. The Project Item that wraps the new Issue is created and populated by `.github/workflows/issues-to-project-mirror.yml` (cluster D mirror workflow) — `/file-directive` does NOT write to the Project directly.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Author the body** from `.claude/templates/directive.md`:
   - **Objective** — bounded by concrete artifact-level boundary (issue counts, file paths, AC ticks, merge events). Refuse to proceed if the Objective doesn't name a concrete artifact-level boundary.
   - **Success signals** — 2 to 5 verifiable conditions. Each must be objectively testable by a reasonable engineer.
   - **Non-goals** — at least 2 explicit exclusions.
   - **Constraints** — at least 1 invariant to preserve.
   - **MISSION fit** — which `MISSION.md` section or success criterion does this Directive serve? (MISSION.md replaces a separate parent-goal artifact.)
   - **Priority** — one of `P0` / `P1` / `P2` / `P3`; ask the user. Defaults to `P2` in unattended mode if not specified. The matching label is applied to the Issue at create time.
   - **Confidence** — 0-100; ask the user.

1.6. **Claim ordering** (SPEC §1.11 L2/L5) — while the body is still yours to edit, take each descriptive fact in L5's order: **delete** it (the default — a claim the body does not need is removed, not sourced); else reduce it to a **pointer** (issue #, path, sha, § heading); only a residue that must appear as a figure is **rendered** via `bash .claude/ghjig-root/scripts/ghjig_evidence.sh evidence '<command>'` — the last rung's instrument, never the step's opening move. Advisory like the citation step below: it gates nothing and changes no reviewer verdict.

1.7. **Citation check** (SPEC §1.10, #676) — resolve the body's quoted spans before the gate step below, so a site-mismatched or fabricated quotation is corrected by the author rather than found by the reviewer:
   - `mkdir -p .claude/ghjig-state/tmp`, write the proposed body verbatim to `.claude/ghjig-state/tmp/proposed-directive-body.md` (in-registry per-project ephemeral state, git-excluded in the shell repo and in every onboarded target — SPEC §3.2.2), then run `bash .claude/ghjig-root/scripts/lint_citations.sh .claude/ghjig-state/tmp/proposed-directive-body.md` — plain argv, the path as one quoted argument.
   - Surface the report to the author as returned: on stdout, one report line plus the indented `search:` line carrying the search that produced it — one such pair per span, except that the `no-attribution` spans are grouped into a single pair — and on stderr, the advisory `citation note` lines naming anything the reader declined to scan, plus the per-class totals. **Surface the notes as well as the totals**: several of the reader's declines are stated only there, and a report relayed without them reads as though the whole body was examined when it was not. Fix a `site-mismatch` (the wording is real, the file it is hung on does not carry it) or an `unresolved` span by re-reading the artifact and re-quoting it; `normalized`, `unresolvable-locally` and `no-attribution` are informational.
   - **The report is advisory.** The reader exits 0 unconditionally and gates nothing: a finding is never a refusal to file, never a park in unattended mode, and never an input to the `activation-reviewer` verdict below. A clean report is the floor the author owes the reviewer, not verification (§1.10).
   - Then `rm -f .claude/ghjig-state/tmp/proposed-directive-body.md`. The staged file is a full draft of a body that has not yet been reviewed, nothing downstream reads it again, and leaving it behind accumulates pre-review drafts on disk indefinitely.

2. **Reviewer gate** — invoke the `activation-reviewer` subagent (SPEC §4.9) on the proposed body. Pass: proposed body, list of currently `Active` Directives (`gh issue list --label directive --label '-status:proposed' --state open --json number,title,body --limit 100`), MISSION.md content. Parse the verdict line.

   Verdict dispatch (SPEC §2.1, §5.7.1 operating-mode coupling):
   - **`pass`** → proceed to step 3.
   - **`revise: <feedback>`** → revise the body per the one-line feedback. Re-invoke `activation-reviewer` on the revised body. The reviewer **self-escalates to `reject` after N=3 `revise` markers** (the contract SSOT `.claude/agents/activation-reviewer.md`); on that `reject`, surface to the user (attended) or park (unattended).
   - **`reject: <reason>`** → do NOT create the Issue. In attended mode: report the reason and stop. In unattended mode: append one line to `.claude/ghjig-root/.claude/state/directive-block.log` and stop.

3. **Create the Issue**. The `P<P>` priority label is applied **only if it exists** on the target (graceful degradation, SPEC §0.4) — the `directive` label is the hard dependency (enforced by step 0), the `P<N>` label is degradable:
   ```bash
   # P-label is degradable: apply if present, else warn + continue (never abort).
   PLABEL=()
   if gh label list --limit 200 | cut -f1 | grep -qx "P<P>"; then
     PLABEL=(--label "P<P>")
   else
     printf 'warn: priority label P<P> absent on target — filing without it (run scripts/ensure_v3_labels.sh to install P0-P3).\n' >&2
   fi
   gh issue create \
     --title "directive: <Objective summary, ≤80 chars>" \
     --body "<full body from step 1>" \
     --label "directive" \
     --label "status:proposed" \
     "${PLABEL[@]}"
   ```
   Capture the new Issue number `<N>`. The `P<P>` label (one of `P0`/`P1`/`P2`/`P3`) is the priority captured in step 1; the mirror workflow reads this label to populate the Project Item's Priority field. `P0`–`P3` are part of the tier-2 dir-mode label set installed by `scripts/ensure_v3_labels.sh` (SPEC §0.4); the graceful-degradation guard above keeps `/file-directive` working even on a target where they were not installed. **Priority is also recorded in the body `## Priority` field and the step-4 audit line — the label is the mirror-readable projection, not the sole record.**

4. **Audit log** — `audit_log info directive-file created "directive: <Objective summary> issue=#<N> priority=P<P> confidence=<C>"`.

   Both `<P>` and `<C>` are populated from the step-1 collection — emitting them with the placeholder literal (`priority=P<P>`) drops the format-validation contract in `.claude/hooks/hookrt.sh:_audit_validate_format` and produces a `directive-file/format-error` warn entry instead of the requested `created` record. Use the captured values.

   The `issue=#<id>` token is the canonical reference (Issues are SSOT).

5. **Mirror sync** — the `issues-to-project-mirror.yml` workflow fires on `issues.opened` and populates the Project Item's fields. `/file-directive` does NOT wait for the mirror; it returns immediately after the audit line.

6. **Output**:
   ```
   Filed Directive Issue #<N>: <Objective summary>
   Status: Proposed (label: status:proposed)
   Next: /activate <N> when ready (re-runs reviewer; removes status:proposed → Active).
   ```

## Operating mode

- **attended** (default): step 2 surfaces the verdict to the user before applying.
- **unattended**: step 2's verdict gates directly.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /file-directive` bypasses the reviewer gate. This escape is **command-prose-enforced** — no PreToolUse hook reads `directive-review`, so `should_skip` never auto-logs it. To keep the escape audit-logged (SPEC §7 escape contract), on taking the bypass **emit the record yourself**: run `. ".claude/ghjig-root/.claude/hooks/hookrt.sh"` then `audit_log escape directive-review skip "<why>"` (parity with the `should_skip` `SKIP_HOOKS` escape audit).

## Forbidden

- Creating an Issue with an empty or stub-only Objective.
- Skipping the reviewer gate without `SKIP_HOOKS=directive-review`.
- Writing directly to the Project Item — that's the mirror workflow's job.
- Setting the `directive` label without `status:proposed` — Proposed is the first state for any new Directive.

## Work language
Author the **Directive body** (Objective, Success signals, Non-goals, Constraints, MISSION fit) in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the task context into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`.
