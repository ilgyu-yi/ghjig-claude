---
description: DEFAULT Phase-C author. Assemble an explicit manifest (the Plan + the failing Phase-B test + how to run it + the named relevant files + the directive-level learnings), spawn the implementer subagent on it, and absorb ONLY its structured return (commit/diff + plan-deviations + discoveries). /work-on routes the Code phase here by default; the opt-out is for trivial / glue edits. See SPEC §5.28.
---

`/implement <issue#>` runs the Code phase (Phase C) in a write-capable `implementer` subagent (§4.12) instead of the main loop, so the within-Execution authoring churn stays out of the main assistant's context. See SPEC §5.28.

## Default-with-opt-out invariant (Directive #477 signal-4)
The Code phase routes here **by default**: `/work-on`'s Phase-C step dispatches `/implement`. The **opt-out** is for trivial / one-line / glue edits and the orchestrator's own glue (Directive #477 Non-goal 2), which the main assistant authors directly. The default-flip descopes the original A/B measurement gate — the context-narrowing hypothesis is adopted as operating policy on circumstantial evidence, hedged by **fail-open reversibility** (a missing implementer path degrades to main-loop authoring; the documented opt-out makes the default revertible). Auto-routing lives in the `/work-on` doc procedure only — **never** wire automatic dispatch into a Stop / PostToolUse hook.

## Manifest contract (input you assemble and pass)
Before spawning, gather the explicit manifest — the subagent has **no access to this conversation**, so everything it needs must be in the manifest:
- the **Plan** — from the PR body's `## Plan` / `## Checklist` (the planner output, §4.1);
- the **failing Phase-B test** — the test file(s) the test-writer authored, **and how to run it** (the exact command);
- the **named relevant file paths** — the files the implementation will touch (the PR body's `## Key context` is the source);
- the **directive-level learnings** — the distilled `### Learnings for the next Execution` blocks `/work-on` reads back from the parent Directive's `/reflect` comments (§5.15) and injects (closes #477 signal 3). **Advisory context only** — codebase gotchas / conventions / what-to-reuse-or-avoid carried over from sibling Executions; it never gates the implementation. Absent when the Issue has no parent Directive or no enriched reflections yet.

If the Plan or the failing test is missing, the manifest is incomplete — finish Phase A/B first; do not spawn against a partial manifest. The `directive-level learnings` field is optional — its absence does not make the manifest incomplete.

## Spawn
Invoke `subagent_type: implementer` with the assembled manifest. It iterates (reads, tries approaches, runs the test + adjacent regression + lint/smoke) entirely in its own ephemeral context.

## Structured-return contract (output you absorb)
Absorb **only** the subagent's structured return — never the working churn:
- **(a) commit / diff ref(s)** authored,
- **(b) plan-deviations** (where/why it diverged from the Plan),
- **(c) discoveries** (signal worth surfacing).

On a plan-deviation that is **structural** (out-of-plan load-bearing file, an AC rendered unreachable), follow the `/replan-check` discriminator (§5.26): re-invoke `planner`, then curate the PR body via `/sync-pr`. Cosmetic deviations need at most a one-line advisory.

## Work language
The implementer authors its commit in the **work language** (resolved by `resolve_work_lang`, §5.7.2), not the chat language.

## Session-restart caveat (§4.9.3)
Claude Code enumerates `subagent_type` values at session start. A freshly-added `subagent_type: implementer` falls back to `general-purpose` until the next session restart. The fallback is **functionally complete** — `implementer.md`'s self-describing prompt instructs `general-purpose` to behave as the implementer — but the Type-aware tool restriction is lost until restart; restart is canonical.
