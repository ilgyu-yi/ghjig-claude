# ADR 0001: No automated over-scaffold silent-failure metric (yet); retain manual surfacing

- Date: 2026-06-22
- Status: Accepted
- Context PR: #_TBD_

## Context

The MISSION frames enforcement as a two-faced dual: **negative** enforcement refuses a wrong action (a block), and **positive** enforcement supplies the right one (a scaffold, template, `next:` hint, or structured fill). The audit log is named as the dual's *"deferred positive face — the channel through which the shell sees its own friction and improves under use."*

That channel is only **half-built**. The shell instruments the *loud* side richly — every block, warn, and escape is logged, and `scripts/narrowing_candidates.sh` / `scripts/promotion_candidates.sh` aggregate that over-block friction into migration candidates. But the *silent* side — **over-scaffolding**, where positive enforcement guides the agent to a well-formed-but-semantically-wrong artifact that passes every format gate and is caught (if ever) only as a later correction — is uninstrumented. Tuning the enforcement-face equilibrium with only one side visible is structurally biased toward over-scaffolding, because the one cheap, measurable cost (block tokens) over-weights against three expensive-but-invisible ones (silent-failure remediation, template drift maintenance, lost sensing signal).

Issue #420 is the feasibility spike that **must run before** any build Directive for such a sensor: is a *valid* — low-confounding, attributable — silent-fail metric constructible from artifacts this repo already produces, at this repo's scale? A premature build risks a sensor that itself fails confidently-but-wrong (the very failure mode it is meant to detect, one level up).

## Decision

**Do not build an automated over-scaffold silent-failure metric at this time.** A valid metric is **not constructible** from currently-available artifacts. Best practice at the current scale is the existing **surfacing-over-automation** pattern, extended by a **manual** tally: when a fix touches a shell scaffold/contract *and* the linked issue documents that the scaffold was producing wrong-but-well-formed output (the #416 shape), record it by hand alongside the `*_candidates.sh` outputs. This is recorded as the standing decision, with explicit revisit triggers (see Consequences).

The finding rests on three measured obstacles (data from the repo's first month: 657 commits, 166 merged PRs, 228 issues, 192 PRs — `git`/`gh`, 2026-05-21 → 2026-06-22):

1. **No provenance join key.** Artifacts do not record which scaffold produced them. Across the whole history, **zero** commits carry a `produced-via:`/`generated-via:` trailer; the trailers actually in use are `Co-Authored-By:`, `Docs:`, `Verified:`, and `Closes`/`Refs`. Any "scaffold-produced-artifact correction rate" needs a join key from artifact → producing-scaffold that **does not exist** — it can only be computed *after* first building provenance instrumentation.

2. **Instrumentation is loud-side-only by construction.** The audit log's event types are `warn`/`block`/`escape` and its categories are all *enforcement* (`bypass-suspect`, `commit-format`, `force-push`, `out-of-scope`, `secret`, …). No event type records a scaffold *invocation* or scaffold *output quality*. The reviewer-reject channel (#356) records errors that were **caught** — by definition not silent. Nothing in the durable record observes the silent side.

3. **Irreducible attribution confound + base rate too low.** The only available proxy — fix-commits touching the scaffold surface itself (`.claude/commands` 13, `.claude/hooks` 52, `SPEC.md` 22 ≈ 87) — conflates genuine silent-failure remediation with ordinary iterative refinement (the shell "improving under use"). Separating the two required *reading each issue* (human judgment); there is no mechanical discriminator, and at the artifact level a scaffold-error and an agent-reasoning-error co-produce the output and cannot be mechanically separated. Clear silent-failure instances (e.g. #416, where the `/release` template drifted from the conventional-commit hook) run at roughly **1 in ~166 PRs (< 1%)**; detecting a *change* in a sub-1% rate needs sample sizes far beyond current velocity even if the events were attributable.

The spike therefore confirms its own motivating thesis: the silent side is invisible to current instrumentation, and the naive "just build a sensor" move would itself fail confidently-wrong (a proxy metric conflating refinement with silent failure would mislead the very migration decisions it is meant to inform).

## Alternatives considered

- **Build the sensor now from existing artifacts** (the proposed build Directive, executed directly): rejected — there is no provenance join key and no silent-side instrumentation, so the only computable quantity is an *overall* correction rate that conflates scaffold failure with ordinary bugs and reasoning errors. A migration trigger tuned on that is worse than none.
- **Add cheap provenance stamping first** (a `produced-via: /work-on|/ship|/release` trailer or audit line), then measure: deferred, not adopted now — it is a modest build, but even with a clean join key the attributable base rate (< 1% of PRs) is too low to detect a *change* at current velocity, and the scaffold-vs-reasoning confound at the artifact level remains. Listed as the **prerequisite** a future revisit would start from, not work to do today.
- **Use the proxy (scaffold-surface fix-commits) as the metric**: rejected — it is dominated by ordinary refinement, not silent-failure remediation, and required per-issue human reading to classify. As an *automated* signal it would be mostly noise.
- **Treat the reviewer-reject channel as the silent-fail signal**: rejected — it records *caught* errors, which is the loud side by definition; it cannot observe failures that pass the gates.

## Consequences

- **Positive.** Avoids building a confidently-wrong sensor and tuning enforcement-face migration on a biased metric. Keeps the proven surfacing-over-automation stance (`*_candidates.sh`) intact rather than reversing it. The no-go is a decision-closing output — the spike cannot "fail" by reaching it.
- **Negative / accepted residual.** The over-scaffold side remains uninstrumented; enforcement-face migration decisions stay partly judgment-based, leaning on the loud-side candidates plus the manual tally. The known bias toward over-scaffolding is *named and accepted*, not eliminated.
- **Revisit triggers** (any one flips this decision back to open): (a) the scaffold surface materially grows (e.g. many more generative slash-commands/templates), raising the attributable base rate; (b) velocity rises enough that a sub-1% rate becomes statistically detectable; (c) provenance stamping is added for an independent reason, supplying the join key as a side effect. On any trigger, reopen with a build Directive starting from the provenance-stamping prerequisite.

## Notes

- Spike issue: #420. Author-side gate: `issue-reviewer` (ship). Observer-side gate: `activation-reviewer` (pass).
- Measurements gathered via `git log`/`git rev-list`/`gh issue list`/`gh pr list` over the repo at 2026-06-22 and the per-project audit log `.claude/eng-state/audit/audit.jsonl`.
- Related instrumentation (loud side): `scripts/narrowing_candidates.sh`, `scripts/promotion_candidates.sh`; reviewer-reject audit records (Directive #356); MISSION "The mechanism" (enforcement dual / deferred positive face); SPEC §6.0 (cost-asymmetry face selection).
