# ADR 0001: v0 director-mode core decisions

- Date: 2026-05-24
- Status: Accepted (Partially Superseded — see header note)
- Context PR: #42 (tracker: #41)

> **Header note (2026-05-26 / Directive #92 cluster J2)**: the Goal-as-substrate-item portion of this ADR is **superseded by [ADR-0003](0003-issues-ssot-substrate.md)** (dir-mode v3 reframe). Specifically: (1) the "GitHub Projects v2 as substrate" decision is narrowed — Project v2 is now a *derived-view* substrate (mirrored from Issues), not the SSOT; (2) the "Goal / Directive / Execution as Project Item types" decision is partially superseded — `Goal` is eliminated as an artifact (MISSION.md is the canonical direction); `Directive` and `Execution` move to Issues-as-SSOT with the Project as a one-direction-mirrored view. All other decisions in this ADR (the work-order, the audit-log shape, the subagent framework, the attended/unattended mode axis) are retained.

## Context

Tracking issue #41 introduces a **directional layer** (Directive, §1.7 / §2.1) above Execution Issues in `claude-eng-shell`. v0 codifies six core decisions that shape every subsequent dir-mode PR (#43–#47 and beyond). Each is the kind of irreversible choice that ADRs exist to preserve (SPEC §1.3 / §5.8) — once Directives populate the substrate, reversing any one of these costs migration work.

The decisions are bundled here, not split across six ADRs, because they are mutually-justifying: "single shell" only makes sense given "same repo," which only makes sense given "GitHub Projects v2 as substrate," which is the shared workflow's storage layer, etc. A future reader who wants to understand why v0 looks the way it does needs the cluster, not any one piece.

## Decision

The six core decisions, accepted as a coherent set for v0:

### 1. Single shell, two modes

Dir-mode and eng-mode are two modes of the same `claude-eng-shell` binary (SPEC §1.7). No separate `dir-shell` or `director-cli` is created.

### 2. Same repository

Directives, Execution Issues, and the Final Goal all live in the **target repository**. No separate `directives` repo, no central planning service.

### 3. GitHub Projects v2 as substrate

A single GitHub Project v2 per target repo hosts all three item types (Goal, Directive, Execution Issue), distinguished by the `Type` custom field (SPEC §1.7). The field schema (`Type / Status / Iteration / Priority / Parent / Confidence / Success Signals`) is locked by a follow-on ADR (`0002-directive-project-field-schema.md`, tracking #41 child #2 / issue #43).

### 4. Same workflow pattern for both modes

Both modes follow generate → review → mode-based-approval → audit (SPEC §1.5). The only difference is which subagents author content and which review it (SPEC §1.7 table).

### 5. Manual mode switching in v0

Users invoke mode-specific commands directly (`/file-directive`, `/activate-directive`, `/complete-directive`, `/list-directives`, `/link-directive` for dir-mode; existing `/file-issue`, `/work-on`, `/ship` for eng-mode). No orchestrator decides when to switch. Orchestration is v1+ (SPEC §0.4).

### 6. Strategic judgment remains external

AI may generate, draft, propose, and review freely at any level. Activation, completion, and revision decisions pass through either a human (attended mode) or `directive-reviewer` (unattended mode, SPEC §4.9). The shell never autonomously decides direction.

## Alternatives considered

Each decision was weighed against at least one realistic alternative. Rejection rationale pairs by decision number:

1. **Separate `dir-shell` binary** — would give clean separation of mode-specific code, but doubles the audit surface, the SessionStart restore logic (SPEC §6.5), the registry guard, and the helper namespace. Two shells would also force a synchronization protocol for the frequent eng-mode/dir-mode boundary crossings (`/file-issue --parent`, `/ship`'s `directive-exec-count` audit). One shell with `Type`-aware hooks (§6.1) is strictly cheaper to maintain and to reason about.

2. **Separate `directives` repo** — easy to argue from a "data hygiene" lens (Directives are not engineering issues), but makes parenting cross-repo, complicates GH Projects scoping (one Project cannot span repos cleanly), and forces users to context-switch repos when alternating modes. Co-located makes the loop natural: an Execution Issue's `Parent Directive: #N` marker resolves in the same repo's issue view.

3. **A custom database or file format for Directives** — gives bespoke schema control but loses GitHub UI inspectability, mobile reachability, and the existing audit trail (`gh api` is already wired). Projects v2 is the cheapest substrate that preserves "a human can read the Goal and its Directives on github.com without our shell installed."

4. **A different workflow pattern for dir-mode** (a longer review cycle, multiple reviewer types, voting) — would introduce a second SSOT for "how decisions are made" that humans and Claude both have to remember. The §1.5 pattern is already documented and tested; reusing it costs less to learn and to verify.

5. **An orchestrator from day one** — would let v0 demonstrate end-to-end automation. Rejected: the orchestrator's stop conditions, kill switches, reviewer-rejection-rate thresholds, and budget controls are themselves design choices that benefit from v0 operating data. Shipping the orchestrator without that data risks elaborating the wrong v1 — exactly the kind of speculative complexity SPEC §0.4 was added to prevent.

6. **Autonomous activation/completion/revision** — would close the loop without human checkpoints. Rejected: violates SPEC §1.5 reviewer-pattern coupling and lets the shell decide direction without recorded responsibility. The `unattended` reviewer-substitution (§4.9) is the principled fallback; full autonomy is not v0 scope.

## Consequences

**Positive**:

- **Pattern reuse.** Dir-mode adds ~5 commands, 1 reviewer, and hook annotations — measured against re-implementing the workflow, this is a thin layer.
- **GitHub UI inspectability** is preserved end-to-end. Anyone with browser access can read the Goal, the Directives under it, and the Execution Issues under each — without installing the shell.
- **Audit log unification.** All dir-mode events join the existing `.claude/audit/audit.jsonl` (SPEC §6/§7). One trail, one query surface (`/audit`).
- **Recursive dogfood is open.** Dir-mode can author the Directive *"Stabilize v0 director-mode"*, which engineers back into dir-mode improvements (tracking #41's validation step).

**Negative**:

- **Six decisions locked simultaneously.** Reversing any one is a multi-PR migration. This bundled ADR makes that scope explicit so future maintainers don't underestimate the cost.
- **`Type`-awareness in hooks** adds a per-fire predicate (cheap, but non-zero) on top of existing branch / format / secret matchers. Cached via `.claude/state/issue-type-cache/` per #46.
- **Strategic decisions still bottleneck on humans (attended) or reviewer subagents (unattended).** v0 does not solve "what should the next Directive be." That is intentional — v0's claim is process scaffolding, not strategic generation.

**Neutral**:

- **Projects v2 API maturity** is good enough today. If GitHub deprecates Projects in favor of a new surface, ADR 0001 will need a successor ADR rather than per-PR code changes.
- **The `Type` field as discriminator** is a v0 compromise — Projects v2 lacks a native "item-kind" concept. A future GitHub feature here would simplify the substrate; until then, the custom field is the canonical signal.

## Notes

- **Tracking issue**: [#41](https://github.com/ilgyu-yi/claude-eng-shell/issues/41).
- **Implementation issue for this ADR**: [#42](https://github.com/ilgyu-yi/claude-eng-shell/issues/42).
- **Field-schema ADR (forthcoming)**: `0002-directive-project-field-schema.md` (tracking #41 child #2, issue #43).
- **SPEC sections introduced alongside this ADR**: §0.4 (v0 non-goals), §1.7 (Operating modes), §2.1 (Directive lifecycle), §4.9 (Director subagents), §5.10–§5.14 (dir-mode commands), and the §6.1 `directive-protect` matcher row + Type-awareness annotation.
- **No code lands with this ADR.** Behavior arrives across tracking #41's children #2–#6 (issues #43–#47).
