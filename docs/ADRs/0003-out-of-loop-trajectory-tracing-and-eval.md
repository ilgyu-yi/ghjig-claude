# ADR 0003: Out-of-loop trajectory tracing — no bespoke tracer; grow the golden-task eval instead

- Date: 2026-06-22
- Status: Accepted
- Context PR: #432

## Context

The MISSION names the audit log as the enforcement dual's *"deferred positive face — the channel through which the shell sees its own friction and improves under use."* That channel records only enforcement events. Issue #425 is the feasibility spike for generalizing it to a full **out-of-loop trajectory trace** (tool calls, decision points, token usage) and a behavioral-**eval** consumer on top.

The load-bearing design seed (from the originating discussion): the narrowing axis constrains the **acting context**, not what is **recorded**. Recording is free; *reading-back* is the cost. So a trace consumed only by out-of-loop consumers (a human dashboard, an offline analysis/eval agent) — never re-injected into the acting agent's context — is narrowing-compatible by construction, exactly as the audit log already is.

Two substrate facts, surveyed, reframe the question away from "build a tracer":

1. **The acting trajectory is already recorded.** The harness emits a per-agent JSONL transcript (under the session `tasks/` directory) — a complete native record of tool calls and decisions — and the shell's own `audit.jsonl` records the enforcement-event slice with a stable schema (`ts / event / category / decision / reason / cwd / source`). Between them, the trajectory substrate largely **already exists**; the shell would be duplicating the harness to build a bespoke tracer.

2. **A golden-task eval consumer already has a seed.** Smoke **§42e** (`CLAUDE_ENG_BEHAVIORAL_SMOKE=1`) already shells out to the live agent with synthetic golden inputs (a minimal-valid Directive body, a section-missing body, a minimal-valid Execution body) and asserts the reviewer's verdict. That is a working — if tiny — golden-task behavioral eval, env-gated and offline-by-default.

## Decision

**Do not build a bespoke trajectory tracer. Formalize the out-of-loop invariant as a principle, and invest incrementally in the golden-task behavioral-eval suite (seeded by §42e) as the real lever. Treat the harness JSONL + `audit.jsonl` as the existing trace substrate.**

Three parts:

- **NO-GO: a bespoke tracer.** The harness JSONL transcript already records the acting trajectory and the audit log already records the enforcement slice. A shell-built tracer would be a second representation of data the harness owns — the duplicate-substrate / drift cost ADR-0001 and §9 warn against — for little gain. If a durable aggregation across sessions is later wanted, it should *consume* the existing JSONL/audit records out-of-loop, not re-capture them.

- **GO (incremental): grow the golden-task eval suite.** This is the real value and the genuine gap. §42e proves the mechanism; the lever is *more* golden fixtures + assertions (more reviewer-verdict cases, and — once the trajectory is consulted — path-level assertions, not just final-verdict). Crucially this **escapes ADR-0001's attribution confound**: a golden task has a *known-correct* answer, so a wrong outcome is attributable to the change under test — unlike the silent-fail sensor, where scaffold-error vs reasoning-error co-produced the artifact with no provenance join. Eval is the tractable cousin ADR-0001 pointed at.

- **GO (cheap, documentary): formalize the out-of-loop invariant.** Record as a standing principle that any trace/record may be written freely to durable storage but **must never be re-injected into the acting agent's context** — recording is narrowing-free; reading-back is the cost. This keeps future tracing/eval work narrowing-compatible by construction and is the generalization of the audit log's existing write-now/read-later shape.

## Alternatives considered

- **Build a full bespoke trajectory tracer now** — rejected: duplicates the harness's native JSONL transcript + the audit log; a second representation to keep in sync for marginal gain (the substrate already exists). Re-capture is the wrong move; out-of-loop *consumption* of the existing records is the right one if aggregation is later needed.
- **Build the trace + eval as one big capability now** — rejected: over-scoped for a single unit, and the trace half is largely already present. The eval half is where the value is and it grows incrementally from §42e — no need to couple them.
- **Re-inject the trace into the acting loop for self-correction** — rejected outright: the forbidden inverse. It violates narrowing (grows the acting context with prior-step noise) and is exactly what the out-of-loop invariant exists to prevent. In-loop self-correction is a different mechanism (cf. the re-plan checkpoint, #427), not trajectory re-injection.
- **Do nothing** — rejected: the eval gap is real (today only §42e's three assertions exist), and it is the most tractable instrument for "is the shell improving under use" — the question ADR-0001 left unanswerable on the silent-fail axis but which golden-task eval *can* answer.

## Consequences

- **Positive.** Avoids a duplicate tracer; directs effort to the eval suite (the real lever) and escapes ADR-0001's confound via known-correct golden answers. The out-of-loop invariant, once documented, keeps all future tracing/eval narrowing-safe by construction.
- **Negative / accepted residual.** No cross-session durable trajectory store is built; if one is ever wanted it must be a follow-up that *consumes* the harness JSONL out-of-loop (not re-captures). The eval suite grows by hand (more fixtures) — deliberate, to keep it offline-deterministic and reviewable.
- **Follow-up (not built here — scoping spike).** A build issue to *grow the §42e golden-task eval suite* (more reviewer-verdict fixtures, env-gated, offline-default). A documentation issue to *write the out-of-loop invariant into SPEC* as a standing principle. No tracer build.

## Notes

- Spike issue: #425. Gates: issue-reviewer (ship), activation-reviewer (pass).
- Substrate surveyed: the harness per-agent JSONL transcript (session `tasks/` dir); `.claude/eng-state/audit/audit.jsonl` (schema `ts/event/category/decision/reason/cwd/source`); smoke §42e (`CLAUDE_ENG_BEHAVIORAL_SMOKE=1`, the golden-task eval seed).
- Distinct from ADR-0001 (#420): that was a no-go on a silent-fail *sensor* (attribution confound); golden-task eval has known-correct answers and escapes it. Distinct from ADR-0002 (#424): generation-side structured-fill.
- Related: MISSION "The mechanism" (audit log as deferred positive face; narrowing/injection dual); SPEC §6.0; §9 (don't multiply representations); smoke §42e.
