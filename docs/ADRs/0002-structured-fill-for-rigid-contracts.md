# ADR 0002: Structured-fill for rigid contracts — slot-assembly helpers, commit subject first

- Date: 2026-06-22
- Status: Accepted
- Context PR: #431

## Context

The MISSION enforcement dual has a *positive* face: supply the right next action, not only refuse a wrong one. For a **rigid, stable** contract, the strongest positive form is "fill a schema/template" rather than "free-write, then a regex rejects what was wrong" — making malformed output structurally hard instead of merely caught. ADR-0001 covered the *measurement* side of the dual (a no-go on a silent-fail sensor) and explicitly left this **generation** side open.

Issue #424 is the feasibility spike for the generation side: which of the shell's rigid contracts should migrate toward structured-fill, by what realistic mechanism, and at what cost-asymmetry per contract. The recurring format friction motivating it is concrete — the `#416`/`#417`-era commit-subject false-positives and the live design thread on shifting enforcement left.

The shell's rigid/stable contract surfaces, surveyed:

| Contract | Rigidity | Stability | Frequency | Today |
|---|---|---|---|---|
| Commit subject `<type>(#N): …` | high (regex) | high | very high | free-text `git commit -m` + `commit-format` hook |
| Issue / Task / Directive bodies | medium (sections) | high | medium | `.claude/templates/*.md` fill + issue-/activation-reviewer net |
| ADR body | medium | high | low | `/adr` template fill |
| Changelog fragment | high (one bullet `(#N)`) | high | high | `/changelog` + `check-changelog` CI net |
| PR body | low (editorial) | low | high | curated prose (PR-as-living-doc) |

## Decision

**Adopt structured-fill selectively, via slot-assembly helpers, and migrate the commit subject first. Keep the form-based contracts at their current template-fill + reviewer/CI net; do not migrate the PR body.**

Two load-bearing findings shape this:

**1. The realistic mechanism is a slot-assembly helper, NOT constrained decoding.** The shell does not control Claude Code's generation mode: artifact authoring flows through free-text `Bash`/`Edit`/`gh`, and there is no constrained-decoding API the shell can invoke for these surfaces (the harness's structured-output/schema facility exists for *subagent* returns, not for the main agent's `git commit` / `gh issue create`). So "fill a schema" cannot be a true grammar constraint here. The achievable strongest form is a helper that **assembles** the artifact from slot arguments — the agent supplies the slots, the helper guarantees the format — with the existing hook retained as the net. This is positive enforcement (supply the right next action) paired with the negative gate, exactly per §6.0.

**2. Cost-asymmetry selects per contract.** Structured-fill earns its keep only where the contract is rigid+stable AND high-frequency AND a wrong free-write is a recurring cost:

- **Commit subject → GO (first and primary target).** Highest frequency, most rigid, most stable. A `commit_subject`/`eng_commit <type> <issue> <subject>` assembly helper builds the `-m` string itself, so the format is guaranteed at generation and the agent never hand-types `git commit -m "<type>(#N): …"`. Wrong-fill cost is low (amend) and the `commit-format` hook still nets it. It also shrinks a false-positive class: once real commits go through the helper, a literal `git commit -m` appearing in a command is *always* a non-commit (a grep pattern, an example), which lets a future matcher-precision pass (separate work) stop firing on those without risk. Composes with, does not replace, the hook.
- **Issue / Directive / ADR bodies → NO-GO (already there).** These are *already* template-fill (`.claude/templates/*.md`) with a reviewer net (issue-reviewer / activation-reviewer). The marginal gain from a stricter generation mechanism is low, and a richer body benefits from reasoning, not slot-locking. Keep as-is; the reviewer is the right net for prose-bearing forms.
- **Changelog fragment → DEFER (marginal).** Rigid and high-frequency, but already template-shaped (`/changelog`) and CI-netted (`check-changelog`). A one-line assembly helper is possible but low-value; revisit only if fragment-format friction recurs.
- **PR body → NO-GO (anti-fit).** Editorial by design (PR-as-living-doc, §1.4); its value is curated prose. Schema-fill would fight the contract, not serve it.

## Alternatives considered

- **Constrained decoding / a StructuredOutput tool for the main agent's artifact authoring** — rejected: not available. The harness does not expose constrained generation for `Bash`/`gh`-authored artifacts; only subagent returns can be schema-forced. Treating the unavailable mechanism as the plan would be a non-starter.
- **Migrate all rigid contracts at once** — rejected: the form-based contracts are already template+reviewer-netted, so a blanket migration adds maintenance surface (a second representation of each contract — the same drift cost ADR-0001 and §9 warn against) for near-zero gain, and would mis-fit the editorial PR body.
- **Do nothing; rely on the regex hooks alone** — rejected for the commit subject specifically: the recurring hand-authoring of the subject is exactly the high-frequency rigid-contract case where the positive face earns its keep; leaving it free-write keeps re-paying the friction.
- **Skip the helper, just tighten the matcher** — rejected as the *primary* move: matcher precision (not firing on non-commit `git commit` literals) is complementary and worth doing, but it is the negative-side fix; it does not supply the positive generation-time guarantee. Do both; this ADR commits to the positive half.

## Consequences

- **Positive.** A commit-subject assembly helper guarantees format at generation for the highest-frequency rigid contract, removes the recurring hand-authoring friction, and (downstream) enables a safe matcher-precision pass. The selective scope avoids multiplying contract representations.
- **Negative / accepted residual.** Not true constrained decoding — the helper can still be bypassed (an agent can hand-write `git commit -m`), so the hook net stays mandatory; the helper is positive guidance, not a gate. The form-based contracts remain reviewer-netted rather than generation-constrained (accepted: prose forms want reasoning, not slot-locking).
- **Follow-up (not built here — this is a scoping spike).** A build issue for the commit-subject assembly helper (the GO target), and a separate matcher-precision issue for not firing on non-commit `git commit` literals. The form contracts need no follow-up.

## Notes

- Spike issue: #424. Gates: issue-reviewer (ship), activation-reviewer (pass).
- Independent of ADR-0001 (#420): that was a no-go on *measuring* silent over-scaffold failure; this is the *generation* side the ADR left open.
- Contract surfaces surveyed: `.claude/hooks/helpers/conventional_commit.sh` (`re_required`/`re_optional`), `.claude/templates/{issue,directive,adr,pr_body}.md`, `/changelog` + `.github/workflows/check-changelog.yml`.
- Related: MISSION "The mechanism" (enforcement dual / positive face); SPEC §6.0 (cost-asymmetry face selection); §9 (thin-pointer / don't-multiply-representations).
