# ADR 0005: Offered-not-forced capabilities get exactly one in-band reference — only `/recall` is at zero

- Date: 2026-06-23
- Status: Accepted
- Context PR: #_TBD_

## Context

The MISSION enforcement-dual positive face has two faces in time: an **in-band** message a step emits, and a **deferred/latent** face (a record consulted later). A capability that is "offered, not forced" leans latent — it exists, but nothing prompts it, so the agent must *remember* to invoke it. Issue #441 asks whether the three recently-shipped positive-face capabilities (`/recall` #422, `/replan-check` #427, `eng_commit` #436) actually get invoked, and whether a cheap in-band nudge is warranted per capability — without over-prompting (which grows the acting context against the narrowing principle).

Surveyed adoption (where each capability is referenced as a workflow step, excluding its own definition):

| Capability | In-band references today | Natural trigger point |
|---|---|---|
| `/recall` | **none** (only its own command file) | before planning ("have we addressed this shape?") |
| `/replan-check` | `/sync-pr` step 7 (post-sync advisory, added in #427) | after a body sync / phase commit |
| `eng_commit` | `/work-on` commit step + CLAUDE.md pointer (#436) | the commit step |

The key reframe: **"offered, not forced" is not monolithic — it has degrees.** Two of the three already received exactly one in-band reference at their natural trigger (wired in their own PRs); only `/recall` is at *zero* — purely latent, with no surface that ever points at it.

## Decision

**A positive-face "offered, not forced" capability gets exactly ONE in-band reference at its natural trigger point — zero is the adoption gap, more than one is over-prompting. Only `/recall` is at zero, so it (alone) gets a nudge; `/replan-check` and `eng_commit` are already adequately surfaced.**

- **`/recall` → GO (one cheap in-band reference).** Add a single suggestion at `/work-on`'s pre-planning step: before invoking `planner`, *consider* `/recall <topic>` to surface prior decisions on the same shape. Cost-asymmetry: one ignorable line in a skill the agent already reads while planning — a wrong nudge is free, while a never-invoked retrieval capability is dead weight and starves the injection half of the dual. (Routed to a follow-up build issue; not built in this spike.)
- **`/replan-check` → NO-GO (already surfaced).** Its `/sync-pr` step-7 reference is the one in-band reference at its natural trigger. Adding more would be over-prompting.
- **`eng_commit` → NO-GO (already surfaced).** Its `/work-on` commit-step offer + the CLAUDE.md pointer are the one in-band reference. No more.

**The reusable rule** (the real finding): the positive-face in-band/latent dual implies a *one-reference norm* — each offered capability should be referenced once, at its natural step, by the skill that reaches that step. Zero references (purely latent) is an adoption regression; two-plus is a narrowing regression (over-prompting). This norm is the cheap discriminator the cost-asymmetry prescribes, and it generalizes to future capabilities.

## Alternatives considered

- **Surface capability suggestions via the per-turn `next:` statusline hint** (`status.sh`) — rejected: the `next:` hint is driven by the Plan's next *checklist* item; coupling it to capability-prompting would over-prompt every turn (a narrowing regression) and entangle the statusline with a concern it doesn't own. The natural skill step is the right home, not the always-on statusline.
- **Add an in-band nudge for all three capabilities uniformly** — rejected: `/replan-check` and `eng_commit` already have their one reference; a second would be over-prompting. The survey shows the gap is specific to `/recall`, not uniform.
- **Force any capability (hook/gate)** — rejected: out of scope and against the "offered, not forced" design; the gate stays the net, the nudge is positive guidance only.
- **Do nothing (leave `/recall` purely latent)** — rejected: zero integration means the capability is likely never invoked, the build effort is dead weight, and the injection half of the dual (which `/recall` exists to serve) stays unfed.

## Consequences

- **Positive.** `/recall` gets the one cheap reference that closes its adoption gap; the other two are confirmed adequately surfaced (no churn); a reusable one-reference norm is established for future positive-face capabilities, keeping adoption and narrowing in balance by construction.
- **Negative / accepted residual.** The nudge is positive guidance the agent can still skip — adoption is raised, not guaranteed (correct: forcing would violate the design). No measurement of actual invocation rate is built (that would need the trajectory/eval substrate ADR-0003 left as a follow-up).
- **Follow-up (not built here — scoping spike).** One small build issue: add the `/recall` pre-planning suggestion to `/work-on`. No change to `/replan-check` or `eng_commit`.

## Notes

- Spike issue: #441. Gates: issue-reviewer (ship), activation-reviewer (pass).
- Adoption surveyed by grepping `.claude/commands/` for references to each capability outside its own definition (2026-06-23): `/recall` = 0, `/replan-check` = 1 (`sync-pr.md`), `eng_commit` = 1 (`work-on.md` + CLAUDE.md).
- Distinct from #422/#427/#436 (built the capabilities) and #442 (the cost-asymmetry light-lane dual of #428).
- Related: MISSION "The mechanism" (positive face — in-band vs deferred/latent); SPEC §6.0 (cost-asymmetry); ADR-0003 (the eval/trajectory substrate an actual invocation-rate measurement would need).
