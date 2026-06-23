# ADR 0006: No light review lane — the compressible gates are already conditional; the floor is irreducible

- Date: 2026-06-23
- Status: Accepted
- Context PR: #445

## Context

Every change this session traversed a full gate set (~15-25 tool calls, ~3-4 reviewer subagents). Issue #442 asks whether the *dual* of #428's high-asymmetry N-way tier exists: a **light lane** for *low*-asymmetry trivial changes that reuses the `blast_radius.sh` classifier "in the opposite direction" to compress the reviewer gates. The central concern is **bypass risk** — a light lane must not route a substantive change around review, and the #428 high-asymmetry gates must never be reachable through it. A no-go ("the ceremony is the floor") is a valid decision-closing output.

Surveyed: which gates a change actually traverses, and which are already conditional on risk:

| Gate | Always-on? | Already blast-radius-gated? |
|---|---|---|
| `planner` + `plan-reviewer` (`/work-on`) | **no** | yes — required only for 3+ files / schema / API / external-contract changes (SPEC §4.1) |
| `security-reviewer` (`/ship`) | **no** | yes — only when the diff touches a security surface (`/ship` step 2) |
| Doc → Test → Code phasing | **no** | yes — relaxed for `fix`/`refactor`/`perf`/typos (CLAUDE.md work-order) |
| `activation-reviewer` (`/activate`) | yes | no |
| `code-reviewer` (`/ship`) | yes | no |

The reframe this survey forces: **most of the proposed "light lane" already exists** — `planner` (conditional on file count), `security-reviewer` (conditional on surface), and Doc→Test→Code phasing (relaxed for trivial change types) are *already* the low-asymmetry lane. The only gates that fire regardless of risk are `activation-reviewer` (issue quality) and `code-reviewer` (diff quality).

## Decision

**Do not build a light review lane. The genuinely-compressible gates are already conditional; the two always-on gates (`activation-reviewer`, `code-reviewer`) are an irreducible floor because skippability cannot be certified without doing the review.** Record the existing conditional lane as the answer.

The NO-GO rests on four findings:

1. **The compressible parts already exist.** `planner`/`plan-reviewer`, `security-reviewer`, and Doc→Test→Code are each already gated on risk (file count / security surface / change type). A trivial one-file fix already skips `planner` (hence `plan-reviewer`), `security-reviewer`, and the strict phasing. The "ceremony tax" on a genuinely trivial change is already much smaller than the worst case; the worst case is paid by *substantive* changes, which should pay it.

2. **"Low-asymmetry" is not a certifiable skip-class.** #428's classifier identifies an *enumerated* high-asymmetry set (security-surface merge, force-push, directive-completion, irreversible-ADR). Read "in reverse," its complement is *"everything not on that list"* — which is **most changes, including substantive ones**, not a curated "trivially-safe" set. There is no symmetric enumerable set of "safe to skip code-review." Certifying that a specific change is review-skippable requires looking at the diff — i.e. doing (a mini-)review — so the classification is **circular**: you cannot cheaply know a change is safe-to-not-review without reviewing it.

3. **This session's evidence falsifies the premise.** `code-reviewer` caught **real bugs on routine-looking changes** this session: the `/recall` ADR-scope cross-repo bug (#429), the force-push false-NEGATIVE (#437), and the symbol-nav category error (#426). All three were `docs`/`feat`/`fix` changes that a blast-radius classifier would file as "low-asymmetry." A light lane that skipped `code-reviewer` on "low-asymmetry" would have **merged those defects**.

4. **The cost is compute, not human friction.** The reviewer gates are worktree-isolated subagents that run automatically (and, in `unattended`, substitute for human review). The "tax" is tokens/wall-clock, not operator effort. The MISSION trades compute for quality deliberately. So the cost-asymmetry tilts hard toward keeping the gates: a wrong *lighten* (a merged bug — demonstrably real, item 3) vastly outweighs the compute saved by skipping a review.

## Alternatives considered

- **Reuse `blast_radius.sh` in reverse to auto-skip reviewer gates for `is_high_asymmetry == false`** — rejected: the complement of the enumerated high set is most changes, not a safe-to-skip set (finding 2); it would have skipped review on this session's three caught bugs (finding 3).
- **A curated enumerated "trivially-safe" set (mirror of #428's high set) that skips `code-reviewer`** — rejected: no such set is reliably enumerable (a typo PR can still touch a load-bearing matcher line); the skip-condition can't be certified without reviewing, and the asymmetry (merged bug ≫ compute) doesn't justify the risk.
- **Compress `activation-reviewer` for tiny issues** — rejected: a small issue makes the review cheap anyway, so the saving is marginal while an ill-formed issue still slips; low value, real risk.
- **Do nothing and leave the ceremony as-is** — accepted, with the constructive reframe: the conditional gates already *are* the light lane; document that rather than build a new mechanism.

## Consequences

- **Positive.** No new bypass surface on an irreversible-quality boundary; the existing conditional gating (planner/security/phasing) is recognized as the already-present light lane; this session's reviewer-caught-bug evidence is preserved as the rationale; future "ceremony is heavy" proposals have a decisive reference.
- **Negative / accepted residual.** Substantive changes keep paying the full reviewer cost (correct — they carry the risk); genuinely-trivial changes keep the two always-on gates. The compute cost of the floor is accepted as the price of the quality the MISSION optimizes for.
- **No follow-up build.** The constructive output is documentary (this ADR + the survey); optionally, a one-line note in CLAUDE.md that the conditional gates *are* the low-asymmetry lane could be a tiny doc follow-up, but no mechanism is warranted.

## Notes

- Spike issue: #442. Gates: issue-reviewer (ship), activation-reviewer (pass).
- The dual of #428 (which built the high-asymmetry N-way tier). The asymmetry is real but the dual is not symmetric: a high-asymmetry set is enumerable; a "safe-to-skip" set is not.
- Evidence (this session): `code-reviewer` caught #429 (ADR-scope cross-repo), #437 (force-push false-negative), #426 (category error) — all on routine-typed changes a light lane would have lightened.
- Related: MISSION "The mechanism" (cost-asymmetry; quality over compute); SPEC §6.0; SPEC §4.1 (planner-required threshold — the already-conditional gate); ADR-0003 (an actual invocation/defect-rate metric would need the eval substrate, left as a follow-up).
