---
description: Close a Directive Issue as Completed — activation-reviewer evaluates evidence; closes Issue with --reason completed.
argument-hint: <issue-#>
---

Close a Directive Issue with `--reason completed`. Requires `activation-reviewer` evaluation of success-signal satisfaction by linked Execution Issues.

Issue close-as-completed IS the Status=Completed signal. The Project Item's Status field follows via `.github/workflows/issues-to-project-mirror.yml`.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx directive` fails. Fail-open on `gh` network errors.

1. **Resolve the Issue** — `<issue-#>` is a GitHub Issue number. Fetch:
   ```bash
   gh issue view <issue-#> --json title,body,state,labels
   ```
   - If `state != OPEN`: error ("Directive is not open — current state `<X>`") and stop.
   - If `directive` label absent: error ("Issue #<N> is not a Directive (`directive` label missing)") and stop.
   - If `status:proposed` label is present: error ("Directive is in Proposed state — activate first via /activate") and stop.

2. **Collect linked Execution Issues** — search for Issues whose body contains `^Parent Directive: #<issue-#>$`:
   ```bash
   gh issue list --search "in:body \"Parent Directive: #<issue-#>\"" --state all \
     --json number,title,state,body,closedAt --limit 100
   ```
   - For each linked Issue: parse its AC ticks (`^- \[(x|~| )\] ` lines from the body) and its open/closed state.

3. **Read the Directive's success signals** from its body (the `## Success signals` section authored at `/file-directive` time).

4. **Reviewer gate** — Directive completion is a **high-asymmetry** decision (SPEC §4.11): a wrong "complete" is irreversible (it closes the Directive). Source `$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/blast_radius.sh`; `is_high_asymmetry directive-completion` holds, so run the evidence evaluation as an **N=3 independent majority vote** of `activation-reviewer` — three independent, worktree-isolated, artifact-only invocations with no shared context, **2 of 3** pass required. (On a `safe_source` miss, degrade to a single `activation-reviewer` with an `audit_log warn reviewer-tier` — never a lockout.) Each invocation gets:
   - The Directive body (with success signals as written).
   - The list of linked Execution Issues + their states + AC ticks.

   Parse each verdict per `/file-directive` step 2 dispatch; the **majority** verdict is the gate. A non-majority (fewer than 2 pass) leaves the Issue open.

   On `reject` (evidence insufficient): stop. Issue stays open. Audit `directive-complete blocked "<reason>"`. Surface the verdict reason to the user. **Reject-audit emission** (SPEC §6.1, Directive #356 signal 3) — also emit one categorized reject record: source `hookrt.sh` + `safe_source helpers/reviewer_audit.sh reviewer-reject`, then `reviewer_reject_audit activation <reason-class> <issue-#>`, mapping the reviewer's reason to the nearest **reason-class** token (`schema-incomplete` / `unverifiable-ac` / `scope-bleed` / `mission-misfit` / `conflict` / `evidence-insufficient`). Observability only.

5. **Post the closing comment** with per-signal evidence:
   ```markdown
   ## Directive Completion (resolved by activation-reviewer pass verdict)

   - **Signal 1**: <signal text> — Evidence: PR #M (closed); AC #X ticked. Status: ✓
   - **Signal 2**: <signal text> — Evidence: PR #Y, #Z; smoke §N passes. Status: ✓
   - ...

   Closed via /complete-directive.
   ```
   Post this comment via `--body-file` (#504): write the rendered block to a temp file, then `gh issue comment <issue-#> --body-file <file>`. Never inline `--body` — the `<signal text>` is copied from the Directive body and may contain backticks / code (Success signals may reference code reality), which inline interpolation would execute or corrupt. Mirrors the dir-mode `--body-file` bar (`/reflect`, `/revise-directive`, `/consume-initiative`).

6. **Close the Issue** — `gh issue close <issue-#> --reason completed`.

   Note: the `trusted-filer-mutate` hook matcher (SPEC §6.1) allows `gh issue close --reason completed` on trusted-filer Issues without further confirmation. Closing as `not planned` or `duplicate` would require human confirm even after step 5 — `/complete-directive` only uses `--reason completed`.

7. **Audit log** — `audit_log info directive-complete completed "directive: #<issue-#> linked-execs=<N>"`.

8. **Mirror sync** — the mirror workflow fires on `issues.closed` and updates the Project Item's Status field to Completed.

9. **Output**:
   ```
   Completed Directive #<issue-#>: <Title>
   Status: Completed (Issue closed --reason completed)
   Evidence: <N> linked Execution Issues; all success signals satisfied.
   ```

## Operating mode

- **attended**: step 4's verdict surfaces to the user before closing.
- **unattended**: step 4's verdict gates directly; `reject` leaves Issue open.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /complete-directive <issue-#>` bypasses the reviewer (SPEC §2.1, §7).

## Forbidden

- Closing without a `activation-reviewer` pass verdict (or audit-logged `SKIP_HOOKS=directive-review` escape).
- Closing with `--reason not planned` or `--reason duplicate` (use a separate `gh issue close` invocation with explicit reason + human confirm; the `trusted-filer-mutate` matcher blocks the not-planned case on trusted-filer Issues per SPEC §1.5).
- Closing without the closing comment (step 5) — the comment is the canonical evidence record.
- Writing to the Project Item directly — the mirror handles the Status field.

## Work language
Author the **closing comment** (the per-signal evidence record) in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the task context into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`.
