---
description: Consume an upstream Initiative — extract Initiative-parented Directive proposals by working backward from its termination condition. Reviewer-gated; read-only on the Initiative except a comment.
argument-hint: "<initiative-#>"
---

Turn an upstream **Initiative** (an `initiative`-labelled Issue, SPEC §1.7) into Initiative-parented **Directive** proposals, working backward from its termination condition. A prompt-driven skill (script-less, like `/file-directive`): the load-bearing work — judging the contract, decomposing the termination condition, authoring Directive bodies — is reasoning, not mechanizable steps.

**The shell consumes Initiatives; it never authors, edits, closes, relabels, or retires them.** The only write this command makes to the Initiative is a single plain comment (step 2, under-specified path). It extracts Directives but never *activates* them — activation stays human/reviewer-gated (`/activate`), per generation-open / decision-gated (SPEC §5.7).

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx initiative` fails. Fail-open on `gh` network errors.

1. **Type / location check** — resolve `#N` and require the `initiative` label (`is_initiative_issue`-equivalent: `gh issue view <N> --json labels`). If `#N` is not an Initiative, abort with `"#N is not an Initiative (no 'initiative' label) — /consume-initiative operates only on Initiatives"`. The Initiative is read from the **current repo** (cross-repo Initiatives are out of scope, SPEC §1.7). Read its body: `gh issue view <N> --json title,body`.

2. **Contract gate (I1)** — invoke the `activation-reviewer` subagent (SPEC §4.9, Initiative rulebook, contract-evaluability check I1) on the Initiative body. The Initiative must carry a **termination condition evaluable without knowledge of the code**.
   - **pass** → proceed to step 3.
   - **revise / under-specified** → the termination condition smuggles in execution detail (it needs code knowledge to assess). Do NOT guess or fill the gap and do NOT extract. Surface it **upstream** as a plain comment and STOP:
     ```bash
     gh issue comment <N> --body-file <tmpfile>   # body: "From an execution standpoint this Initiative's termination condition is not yet evaluable without code knowledge: <reviewer reason>. Re-specification requested before extraction."
     ```
     `gh issue comment` is the only Initiative write this command performs — it is allowed by the `initiative-readonly` matcher (§6.1), which blocks only `edit`/`close`/`reopen`. File no Directives. Audit `initiative-consume` decision=`under-specified` and return.

3. **Extract — working backward from the termination condition.** This is the novel core:
   - **Restate** the (I1-validated) termination condition as the single observable end-state the Initiative commits to.
   - **Decompose** it into the strategic sub-outcomes that, taken together, would satisfy it. The **necessary-and-sufficient** framing is the *faithfulness criterion the I2 gate checks* (necessary → no sub-outcome exceeds the condition, i.e. no smuggled strategy; sufficient → the set covers the condition, i.e. no gaps) — it is **not** a deterministic decomposition algorithm. The partition is judgment; strategic conditions rarely fall into a clean orthogonal basis. Aim for the smallest set of independent sub-outcomes that covers the condition without reaching past it.
   - **Map each sub-outcome to one Directive proposal**, authored from `.claude/templates/directive.md` (Objective / Success signals / Non-goals / Constraints), PLUS a body **line-1 `Parent Initiative: #N` marker** and **no `## MISSION fit` field** — the parent-XOR is satisfied by the marker (the Initiative traces to MISSION upstream; SPEC §1.7 "Parent generalization"). A Directive's Success signals / Constraints *may* reference code reality — that is exactly why the shell, not the upstream, extracts them.

4. **Faithfulness gate (I2)** — invoke `activation-reviewer` (SPEC §4.9, extraction-faithfulness check I2) over the **whole proposal set at once** (coverage is a property of the set, not of any single Directive).
   - **pass** → proceed to step 5.
   - **revise: <feedback>** → refine the set per the one-line feedback (add a missing Directive / trim scope inflation / fix a parent marker) and re-invoke. After two consecutive `revise` verdicts, escalate to the user (attended) or stop (unattended).

5. **File the extracted Directives.** For each proposal, `gh issue create` with the body passed via **`--body-file`** (so upstream-authored Initiative text carried into the body is never interpolated into a `gh` argument position — this covers the shell-injection surface; content-trust is handled by the I1/I2 gates + human activation, not by `--body-file`):
   ```bash
   # P-label degradable (SPEC §0.4); directive + status:proposed are the hard set.
   gh issue create \
     --title "directive: <sub-outcome summary, ≤80 chars>" \
     --body-file <proposal-tmpfile> \
     --label "directive" \
     --label "status:proposed" \
     "${PLABEL[@]}"
   ```
   The body's line 1 is `Parent Initiative: #N`. At create time the `label-parent-consistency` matcher is **not** engaged (it is scoped to the `--add-label` edit path) — so the **step-4 I2 gate is the effective parent-XOR check** for the create path (it sees the full proposal bodies before filing). The filed Directives are `status:proposed` and are **never activated** by this command. (The body/comment temp files in steps 2 and 5 are created with `mktemp` and `rm`'d after the `gh` call — no predictable path, cleaned up.)

6. **Audit log** — `audit_log info initiative-consume extracted "initiative=#<N> count=<M> directives=<#a,#b,...>"` (decision `extracted`; or `under-specified` from step 2; or `revise` if it halted on the faithfulness backstop).

7. **Output**:
   ```
   Consumed Initiative #<N>: <title>
   Extracted <M> Directive proposals (status:proposed, Parent Initiative: #<N>): #a, #b, ...
   Next: /activate <each> when ready (re-runs activation-reviewer; removes status:proposed → Active).
   ```

## Operating mode

- **attended** (default): the contract gate (step 2) and faithfulness gate (step 4) surface their verdicts to the user before proceeding.
- **unattended**: the verdicts gate directly; an under-specified Initiative halts with the upstream comment, a persistent `revise` halts after two rounds.

## Escape

`SKIP_HOOKS=directive-review SKIP_REASON='<why>' /consume-initiative <N>` bypasses the reviewer gates. Audit-logged.

## Forbidden

- **Never edit, close, reopen, relabel, or retire the Initiative** — it is read-only to the shell (`initiative-readonly`, §6.1). The only permitted Initiative write is the step-2 under-specification comment.
- **Never activate** the extracted Directives — they stay `status:proposed`; `/activate` (human/reviewer-gated) promotes them.
- **Never file a proposal without a line-1 `Parent Initiative: #N` marker**, and never with a `## MISSION fit` field (the parent-XOR — these Directives are Initiative-parented).
- Never extract from an under-specified Initiative (step 2 must pass first) — guessing past a non-evaluable termination condition is the planning/execution boundary violation this flow exists to prevent.
- Skipping the reviewer gates without `SKIP_HOOKS=directive-review`.
