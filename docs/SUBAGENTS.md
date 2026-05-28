# Subagents

Full specs in [SPEC.md §4](../SPEC.md). This page is the practitioner's index — what each subagent does, when to call it, what it expects as input, and what comes back. Subagents protect the main session's context by running specialised work in isolated windows; the main assistant integrates the result.

Subagents fall into three roles. **Explorers** read the codebase. **Builders** produce new artifacts (plans, docs, tests). **Reviewers** judge artifacts and emit a `ship` / `refine` / `block` verdict (SPEC §1.5 operating-mode coupling — in `unattended` runs the verdict gates directly, replacing the human checkpoint).

## Explorers

### explorer

Wide read-only exploration of the codebase. Protects the main context window from large search results.

- **When**: looking for a definition, mapping all callers of a symbol, surveying a feature's surface across many files, or any "where is X" / "who depends on Y" question.
- **Input**: a focused search question — "where is `is_directive_issue` defined and who calls it?", "what hook matchers fire on `gh pr merge`?"
- **Output**: definition pointer + up to 5 reference sites with `path:line` anchors, summarized. No edits.
- **Don't**: re-run searches the main assistant already did (SPEC §1.5).
- **Spec**: SPEC §4.2.

## Builders

### planner

Produces the implementation plan + Doc/Test/Code-ordered checklist that becomes the PR body. **Required** for 3+ file changes, migrations, API/schema changes.

- **When**: invoked by `/work-on` before any edits. Skippable for typo / one-line fix per CLAUDE.md §1.2 relaxation rules.
- **Input**: issue body, target `MISSION.md`, target `CLAUDE.md`, resolved base branch.
- **Output**: plan markdown with mandatory `## Alternatives considered` and `## Target base` sections. The checklist is what the PR body's `## Checklist` consumes.
- **Spec**: SPEC §4.1.

### doc-writer

Phase A. Translates intent into SSOT changes (MISSION, README, CLAUDE.md, ARCHITECTURE, ADR, API docs).

- **When**: invoked when external surface changes — features, contracts, schemas. Skipped for `refactor` with unchanged external behavior.
- **Input**: intent of the change + identified SSOT targets.
- **Output**: patches to existing SSOTs. Proposes a stub for absent docs only with user confirmation (does not invent new SSOT files autonomously).
- **Spec**: SPEC §4.3.

### test-writer

Phase B. Translates the Phase A doc into a failing test, confirms the failure is the intended picture, then hands off to the main assistant for Phase C.

- **When**: right after Phase A on `feat`, `docs`, and external-contract changes. `fix` runs reproduce-first instead (the bug repro plays the spec role).
- **Input**: the Phase A doc/spec.
- **Output**: a test that fails with the expected message; the failure is confirmed before commit.
- **Spec**: SPEC §4.4.

## Reviewers

Reviewers never author content. Each emits a `VERDICT:` line whose values vary per reviewer — most use `ship` / `refine: <one-line>` / `block: <reason>`; `code-reviewer` uses `ship` / `ship after fix` / `block (blocker)` (SPEC §4.5); `triage-reviewer` uses `ACCEPT` / `REJECT — refile as <template>` (SPEC §4.10). Per SPEC §1.5 operating-mode coupling: in `attended` mode the verdict surfaces to the user; in `unattended` mode it gates directly.

### code-reviewer

Pre-commit / pre-PR review. Auto-invoked by `/review` and `/ship`.

- **When**: at the ship gate before `gh pr ready`, and any time `/review` runs.
- **Input**: diff + PR body + MISSION + issue body. No chat context — the reviewer is deliberately uninformed by the conversation that produced the diff, so its verdict comes from the artifacts alone.
- **Output**: `ship` / `ship after fix` / `block (blocker)` with `path:line` anchors on findings.
- **Spec**: SPEC §4.5.

### security-reviewer

Auto-invoked when the diff touches an auth, input-validation, dependency, crypto, or new-IO-boundary surface.

- **When**: any PR whose diff matches security-relevant patterns; not called for prose-only changes.
- **Input**: diff (no chat context).
- **Output**: findings classified High / Medium / Low / Info with risk explanation and remediation.
- **Spec**: SPEC §4.6.

### issue-reviewer

Rationale check on a proposed Issue body before `gh issue create`. Filed Issues that fail the rationale triad never reach the queue.

- **When**: every `/file-issue` invocation. The `--quick` form still runs the rationale check in compressed form.
- **Input**: proposed Issue body, MISSION, snapshot of open Issues.
- **Output**: `ship` / `refine: <one-line>` / `block: <reason>` — verifies (a) MISSION fit, (b) why-now, (c) existing-coverage.
- **Spec**: SPEC §4.7.

### plan-reviewer

Approach + alternatives check on `planner` output. The reviewer enforces that the chosen approach beats the alternatives the planner surfaced — a plan with a thin `## Alternatives considered` section gets a `refine`.

- **When**: after `planner` runs in `/work-on`, before the user (attended) or the harness (unattended) approves the plan.
- **Input**: planner output + issue body + MISSION.
- **Output**: `ship` / `refine` / `block` — `ship` in `unattended` mode substitutes for human plan approval.
- **Spec**: SPEC §4.8.

### directive-reviewer

Quality check on a proposed Directive body (`/file-directive`, `/activate-directive`, `/revise-directive`) or a completion claim (`/complete-directive`).

- **When**: every Directive transition that mutates body content or asserts completion. Annotation-only `/block-directive` does not run this reviewer (no body change).
- **Input**: proposed body or evidence + list of currently Active Directives + MISSION.
- **Output**: `ship` / `refine` / `block`. Five checks: schema completeness, success-signal verifiability, scope clarity, non-goal clarity, Active-Directive conflict. Completion review adds an evidence-sufficiency check.
- **Spec**: SPEC §4.9.1.

### triage-reviewer

Binary classifier for `/triage` — per-Issue template-content match check.

- **When**: every Issue under `/triage`'s queue (Issues carrying `needs-triage` or `status:proposed`).
- **Input**: Issue body + labels + `authorAssociation` passed in the invocation. No `gh` calls; no cross-Issue duplicate scan.
- **Output**: `ACCEPT` (template-content match) or `REJECT — refile as <template>: <reason>` (mis-template usage). Intentionally lighter than `directive-reviewer`; substantive Directive review still happens at `/activate-directive`.
- **Spec**: SPEC §4.10.

## Calling subagents

From within Claude Code, name the subagent in conversation or rely on the skill's auto-invocation:

```
> have planner take this change
> review the PR with code-reviewer
> file the directive proposal (will route through directive-reviewer)
```

`/work-on`, `/ship`, `/file-issue`, `/file-directive`, `/activate-directive`, `/complete-directive`, `/revise-directive`, and `/triage` invoke their reviewers automatically.

## Session-restart caveat

Claude Code enumerates available `subagent_type` values **at session start** by scanning `.claude/agents/*.md`. A reviewer added mid-session falls back to `general-purpose` routing until the next session restart — the agent file is necessary but not sufficient. The fallback is functionally complete (the agent's prompt instructs `general-purpose` to behave as the new reviewer); restart at session end is canonical. See SPEC §4.9.3.

## Parallel invocation

Independent investigations that can run in parallel should be invoked together — multiple Agent calls in a single message. The harness runs them concurrently and integrates results when all return. Reviewers with no dependency on each other (e.g., `code-reviewer` + `doc-writer` SSOT sync on the same PR) batch cleanly.
