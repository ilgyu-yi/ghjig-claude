---
description: Take an issue, create branch + draft PR, invoke planner — all in one. Supports --base for topic-branch / experimental work (SPEC §10.5).
argument-hint: <issue#> [--base <branch>]
---

Parse `$ARGUMENTS`: the issue number plus optional `--base <branch>` (default: the repo's resolved default branch — see step 3; #504). Do the following in order:

1. `gh issue view <#> --json title,body,labels` — read the issue. Print it and give the user a brief summary.
2. **Acceptance criteria check** — if the issue body has no criteria or is vague, ask the user to fix it and stop. **Don't start work with an ambiguous goal.**
3. **Resolve target base** — resolve the repo's **default branch** and **host** in one call `gh repo view --json defaultBranchRef,url` — set `DEFAULT` from `.defaultBranchRef.name` (fallback `main` if unresolvable; #504) and derive the repo host `HOST` from `.url` (strip scheme + path). Reuse `HOST` in step 4; do **not** add a separate host-derivation just for the branch prefix. Then let `BASE` = `--base` arg (default `$DEFAULT`, NOT a hardcoded `main` — a `master`/`release`-default target must resolve correctly). Then `git fetch origin && git checkout "$BASE" && git pull --ff-only`. If `BASE != $DEFAULT` and the named branch isn't reachable locally or remotely, fail loudly — `/work-on` does NOT auto-create alternate bases. See SPEC §10.5 for the topic-branch pattern.
4. Create branch:
   - `USER=$(gh api user --hostname "$HOST" --jq .login)` — host-pinned so a GHES target resolves the correct account (a host-less `gh api user` reads gh's default host, github.com). `HOST` piggybacks off step 3's `gh repo view` call; do not re-derive it.
   - `TYPE` = from issue label or user confirmation (one of feat/fix/docs/refactor/perf/test/style/build/ci/chore/revert)
   - `SLUG` = kebab-case abbreviation of issue title
   - `git checkout -b "${USER}/${TYPE}/<#>-${SLUG}"`
   - If the branch already exists on remote: `git pull --ff-only origin <branch>`.
4.5. **Read back directive-level learnings** (closes #477 signal 3 — the directive-level coding-memory loop). When the Issue body carries a `Parent Directive: #N` marker (line 1, written by `/file-issue --parent`), read the accumulated `### Learnings for the next Execution` blocks from #N's reflection comments (`gh issue view <N> --comments`, the comments `/reflect` (§5.15) enriches). Inject the distilled learnings as **advisory context** into two places: (a) the planner input in step 5, and (b) the `directive-level learnings` field of the `/implement` manifest (§4.12). The injection is **advisory only** — it is context the next Execution starts from, never a gate or a block; absent or empty learnings (no parent Directive, or no enriched reflections yet) is a normal no-op, not an error.

4.6. **Derive the mandatory-invariant manifest** (#568) — before dispatching the planner, derive the **`Mandatory invariants`** field from existing SSOT: the issue AC, the target `MISSION.md`, relevant ADRs, and the affected component's contract. List each declared guarantee a plan must NOT defer, weaken, or measurement-gate; if none apply, the field is explicitly empty ("none declared"). This same `Mandatory invariants` field is threaded into the planner (step 5), both `plan-challenger`s (step 5.6), and `plan-reviewer` (step 6) so the reviewers can run their invariant-preservation gate against it.

5. **Invoke planner agent** — pass issue body, target `MISSION.md`, target `CLAUDE.md`, the resolved `BASE`, **and the step-4.6 `Mandatory invariants` manifest** as input (plus the step-4.5 directive-level learnings as advisory context, when present). Receive **one base Plan A**. The planner **no longer authors `## Alternatives considered`** (SPEC §4.8, #530) — the interested party no longer controls the choice set. The output must include the `## Target base` section (mandatory per SPEC §4.1); the `Target base` value must equal `BASE`. Reject and re-invoke if it is missing or wrong.
5.5. **Axis selection** (SPEC §4.8) — **designate 2 _focus_ axes for this specific change** from the fixed menu `{correctness, simplicity/maintainability, performance, security, cost/effort, robustness/risk, extensibility, UX}` and assign one to each challenger. This is a **weight, not a filter**: the other axes are **not discarded** — the domination bar (§4.8.1, "no worse elsewhere in a way that matters") keeps every axis in view; the focus axes are only where each challenger **leads**. **No hardcoded axis pair** (a fixed pair would relocate the omission bias by systematically excluding performance/security). The selector is homed here — *not* inside a challenger or the reviewer, since mutually-blind challengers cannot self-coordinate distinctness.
   - **Drop-axis attestation** (observe-only; P3 observe-before-harden, Directive #570). Emit one audit record naming the focus/deferred split, so a future friction consumer can observe the **focus/deferral distribution across changes** — e.g. an axis that is never focused, or one focused far more than its peers — which would inform whether the 2-focus cap or the menu needs revisiting (a §4.11-style N-challenger escalation or a menu change — **not built now**). House idiom — source the runtime, then a **bare** `audit_log` (best-effort, never a gate):
     ```bash
     . ".claude/ghjig-root/.claude/hooks/hookrt.sh"
     audit_log info plan-axis focus "focused={<axis1>,<axis2>} deferred={<remaining menu axes>}"
     ```
     The split is **menu-relative** (focused ∪ deferred = the fixed menu); it records no free-floating live-axis count. This emission triggers **no** escalation — it only accrues the record.
5.6. **Challenger dispatch** — dispatch **two independent, mutually-blind `plan-challenger` subagents** (SPEC §4.8.1), **in parallel and worktree-isolated**, one assigned axis each, each also receiving the step-4.6 `Mandatory invariants` manifest. Each attempts to **beat Plan A** and returns one of: dominates-A / genuine non-dominating alternative / reasoned concession (names the axis tried + why A held). This step **rides the planner gate** — it fires exactly when the planner is invoked (non-trivial changes), never on trivial/glue edits; there is **no new tier gate**.
6. **Reviewer gate** — invoke the `plan-reviewer` subagent (see SPEC §4.8) to **judge the contest {A, B1, B2}**. Pass the base Plan A, the two challenger outputs with their assigned axes, the issue body, the target MISSION.md, and the step-4.6 `Mandatory invariants` manifest (so the reviewer runs its invariant-preservation gate). Parse the verdict line (`^VERDICT: (ship|refine|block)`).
   - **`ship`**: proceed to step 7.
   - **`refine: <feedback>`**: re-run the contest with the one-line feedback (re-invoke `planner` and/or re-dispatch the challengers as the feedback indicates), then re-invoke `plan-reviewer`. After two consecutive `refine` verdicts on the latest contest, escalate to the user (or, in unattended mode, treat as `block`).
   - **`block: <reason>`**: stop and post a `gh issue comment` on the linked issue naming the structural problem. In unattended mode, also append one line to `.claude/ghjig-root/.claude/state/plan-block.log`.
   - **Reject-audit emission** (SPEC §6.1, Directive #356 signal 3) — on **any** non-pass verdict (`refine` or `block`), emit one categorized audit record: source `hookrt.sh` + `safe_source helpers/reviewer_audit.sh reviewer-reject`, then `reviewer_reject_audit plan-review <reason-class> <issue#>`, mapping the reviewer's reason to the nearest **reason-class** token (`schema-incomplete` / `unverifiable-ac` / `scope-bleed` / `mission-misfit` / `conflict` / `evidence-insufficient`). Observability only — it never changes the verdict's effect.
7. **Wait for user approval of the plan.** Approval requires an **approach check**: confirm with the user that the winning candidate from the **contest record** (Plan A / B1 / B2 / verdict) is the right one, not just that a plan exists. The approach check is not skipped in Auto / unattended mode. **In `unattended` mode, a clean `plan-reviewer` verdict from step 6 counts as approval** — no human is present, and the reviewer is the substitute.
8. Once approved, **write Phase A (Doc) and make it the first commit on the branch.** Never open the PR with an empty seed commit.
   ```
   # …edit the SSOTs identified by the plan (MISSION, README, CLAUDE.md, ARCHITECTURE, ADR)…
   git add <changed SSOTs>
   # First-line trailer is `Closes #<#>` when BASE is the default branch; else `Refs #<#>`.
   # The issue should auto-close only when work reaches the default branch (SPEC §10.4 / §10.5).
   # Compare against the resolved $DEFAULT (step 3), NOT a hardcoded `main` (#504) — else a
   # master/release-default target wrongly carries `Refs` and the issue never auto-closes.
   TRAILER="Closes #<#>"; [ "$BASE" != "$DEFAULT" ] && TRAILER="Refs #<#>"
   # Co-Authored-By trailer is toggleable (SPEC §10.2). Source the helper
   # and conditionally include the line — the `${COAUTHOR:+…}` expansion
   # injects the leading blank line ONLY when the trailer is enabled, so
   # `off` users don't get a trailing blank in the commit message.
   GR="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/ghjig-root"
   [ -e "$GR/.claude" ] || { echo "GHJig: not inside a registered project (cd to the project root, or run scripts/register.sh)"; exit 1; }
   . "$GR/.claude/hooks/helpers/coauthor.sh"
   COAUTHOR=$(coauthor_trailer)
   git commit -m "<type>(#<#>): <subject>

   ${TRAILER}${COAUTHOR:+

   ${COAUTHOR}}"
   git push -u origin HEAD
   gh pr create --draft --base "$BASE" --title "<type>(#<#>): <subject>" --body "<filled pr_body.md>"
   ```
   `Closes` vs `Refs` — the rule above is the default; the user may override on split (intermediate PR → `Refs`, final consolidator → `Closes`).

   **Recommended assembly path** (SPEC §10.2, ADR-0002): instead of hand-rolling the `git commit -m` above, source `helpers/ghjig_commit.sh` and call `ghjig_commit <type> <#> "<subject>" "<body-para>" "${TRAILER}"` — it validates the assembled `<type>(#<#>): <subject>` via `check_commit_subject` *before* committing and builds the message as a bash argv array (multibyte/multi-paragraph bodies round-trip cleanly; the `commit-format` hook sees and accepts the first-`-m` subject). `ghjig_commit` appends the Co-Authored-By trailer itself when enabled, so pass body paragraphs + the `Closes`/`Refs` trailer as args. Offered, not mandatory — the hand-roll above remains valid.

   If Phase A isn't ready to commit (e.g. planner output needs more clarification), **defer the PR** — keep the issue + plan in conversation. Don't fall back to an empty seed commit just to open the draft PR; see SPEC §5.3.
9. Print "ready to start" message. Continue with the next phase (Test).
10. **Code phase (Phase C) — default route to the implementer.** After Phase B (the failing test) is green-when-it-should-fail, the Code phase routes to the **implementer subagent** via `/implement <#>` **by default** (Directive #477 signal-4 default-flip; SPEC §5.28, §4.12). The main loop assembles the manifest — Plan + failing Phase-B test (and how to run it) + named relevant file paths + the step-4.5 `directive-level learnings` — dispatches `/implement`, and absorbs **only** the structured return (commit/diff ref + plan-deviations + discoveries), so the within-Execution authoring churn (file reads, abandoned approaches, lint/smoke iterations) never re-enters the main loop.
    - **Opt-out** (Directive #477 Non-goal 2) — trivial / one-line / glue edits and the orchestrator's own glue **stay in the main loop**: the main assistant authors them directly rather than paying the dispatch round-trip. The opt-out is **bounded** to that carve-out, not an open license to author arbitrary Code in the main loop.
    - **Fail-open reversibility** (Directive #477 Constraint 5) — if the implementer path is unavailable, the flow degrades to main-loop authoring; the default route is an optimization, never a hard dependency.
    - Reviewer independence (Constraint 3) is unchanged — the Code commit still goes through the normal **pre-ready** review checkpoint: the implementer commits autonomously, and `code-reviewer` runs at `/review` / `/ship` on the landed commit.

## Work language
Author the **commit messages and the PR body** in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the task context into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`. Run the context-recast **before Phase A (Doc)** — the Doc/Test/Code artifacts and every commit subject are work-language.
