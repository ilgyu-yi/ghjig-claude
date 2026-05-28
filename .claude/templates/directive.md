## Objective
<One-paragraph statement of what this Directive is trying to achieve. Must name a concrete artifact-level boundary — file paths, issue counts, AC ticks, merge events — not "improve" or "optimize" without a target.>

## Success signals
- <Verifiable signal 1 — must be objectively testable. e.g., "Issue-reviewer rejection rate drops below 20% over the next 10 issues filed against this Directive.">
- <Verifiable signal 2>
- <Verifiable signal 3>

## Non-goals
- <Explicit exclusion 1 — what this Directive does NOT include.>
- <Explicit exclusion 2>

## Constraints
- <What must hold throughout the Directive's lifetime. e.g., "Do not change attended/unattended mode semantics.">
- <Constraint 2>

## MISSION fit
<Which `MISSION.md` section or success criterion does this Directive serve? One sentence naming the section. e.g., "Serves MISSION's 'Success looks like > The directing layer works' criterion — completes the §2.1 state diagram so the Directive lifecycle is fully executable end-to-end." (Replaces the v0/v1 `Parent Goal` field per ADR-0003 Decision 6. If the repo has no `MISSION.md` yet, say so honestly — the Directive may motivate a MISSION amendment.)>

## Priority
<One of `P0` / `P1` / `P2` / `P3`. P0=drop everything, P1=next, P2=soon, P3=eventually. Default `P2` when filed without explicit user input. The Issue carries the corresponding label; the `_audit_validate_format` validator at `.claude/hooks/hookrt.sh` requires the directive-file/created audit_log call to include `priority=P<N>`.>

## Confidence
<Number 0–100. Self-assessment of hypothesis quality at filing time. Lower numbers are OK — Directives can be filed under uncertainty as long as the success signals are verifiable.>
