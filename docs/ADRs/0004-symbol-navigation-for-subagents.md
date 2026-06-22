# ADR 0004: Symbol navigation for subagents — no LSP/MCP; word-boundary grep is the boundary-safe path

- Date: 2026-06-22
- Status: Accepted
- Context PR: #433

## Context

The MISSION selective-injection half wants relevant material pulled in on demand; symbol-precise navigation (go-to-def, find-refs) is *low-noise* injection — unlike embeddings, it doesn't risk Lost-in-the-Middle. The motivating "why now" (Issue #426) is the #416 review's completeness risk: grep can miss a call-site in a multi-site change. The spike asks whether a **boundary-safe, per-project** way to give subagents symbol navigation is constructible — the central constraint being the shell boundary: *never touch user-global state* (MISSION isolation model: shared code, per-project ephemeral state only).

Surveyed facts that reframe the question:

1. **The codebase is bash-centric.** 53 `.sh` files, ~91 functions across `helpers/`/`scripts/`. A "symbol" here is a bash function; the operations that matter are *go-to-def* (where is `foo()` defined) and *find-refs* (who calls `foo`).
2. **For bash, those operations are nearly a one-liner already.** Go-to-def is `grep -rn '^<name>()' --include='*.sh'`; find-refs is `grep -rn '\b<name>\b' --include='*.sh'`. The word-boundary anchor gives precise-enough matching; the residual imprecision (a call vs a comment mention) is small and cheap to eyeball.
3. **A true LSP requires an out-of-boundary install.** `bash-language-server` is an npm package (node + a server binary + a long-lived process); universal-ctags is a system binary (the platform ships only BSD `ctags`, whose bash support is poor). Installing either globally violates the boundary; installing per-project bolts a heavy dep + lifecycle onto a repo that is not a node project — and across *varied* bound-target languages the shell would owe an unbounded set of per-language servers.
4. **In-boundary storage exists** (`.claude/eng-state/`, gitignored, per-project) — so a generated index *could* be stored boundary-safely; the boundary problem is the binary/server, not the storage.

## Decision

**Do not adopt an LSP/MCP symbol-navigation integration. Treat word-boundary `grep --include='*.sh'` as the de-facto, boundary-safe symbol navigation, and (the only worthwhile change) make find-refs a documented idiom for multi-site changes.**

- **NO-GO: LSP / MCP language-server integration.** Cost-asymmetry (§6.0) is lopsided: the wrong-cost (boundary violation or a global install; a heavy per-project dep + server lifecycle; an unbounded per-language obligation across targets) far outweighs the precision gain over word-boundary grep for a bash corpus. This is the perception-side analogue of an over-injection regression — a heavyweight mechanism that buys little relevant signal at real cost.
- **NO-GO / DEFER: a bespoke grep-backed symbol helper** (`symdef`/`symrefs` in `.claude/eng-state/`). It is fully boundary-safe (pure shell, zero install, per-project) but its gain over plain `grep -rn '\b<name>\b' --include='*.sh'` is marginal at this scale (91 functions) — a thin wrapper around a one-liner the `explorer` subagent already issues. Not worth a new surface now.
- **GO (cheap, documentary): a find-refs idiom for multi-site changes.** The real gap the #416 risk exposed is not *capability* (grep already finds refs) but *discipline* — remembering to enumerate call-sites before a rename/multi-site edit. The worthwhile, boundary-free change is to document the word-boundary find-refs idiom as a step `planner`/`explorer` apply before a multi-site change. (Routed to a follow-up doc issue; not built in this spike.)

## Alternatives considered

- **`bash-language-server` over per-project MCP (`.mcp.json`)** — rejected: `.mcp.json` is in-boundary, but the *server install* (npm/node) is not, the process lifecycle is heavyweight for a non-node repo, and it generalizes badly to varied target languages. Precision gain over word-boundary grep doesn't justify it for bash.
- **universal-ctags index into `.claude/eng-state/`** — rejected: requires installing universal-ctags (the platform ships only BSD `ctags`, weak on bash); the binary install is the boundary cost. Storage would be clean; the dependency is not.
- **A pure-shell `symdef`/`symrefs` helper** — boundary-safe and considered seriously, but deferred: marginal gain over the grep one-liner at 91 functions; adds a surface for little benefit. Revisit if the corpus grows or precision pain recurs.
- **Do nothing, not even document the idiom** — rejected: the #416 completeness risk is real; the cheapest mitigation (documenting the find-refs idiom) is worth taking.

## Consequences

- **Positive.** Keeps the boundary intact (no install, no global state, no per-language obligation), avoids a heavyweight mechanism for marginal gain, and still addresses the #416 risk via the documented find-refs idiom. Word-boundary grep remains the de-facto symbol nav — augmenting, never replacing, the existing grep/glob flow (per the issue's AC3).
- **Negative / accepted residual.** No *precise* call/def/comment disambiguation (grep's residual over-match is eyeballed). Acceptable at this scale; a real cost only if the shell gains non-bash targets where grep symbol-nav degrades.
- **Revisit triggers.** (a) The shell gains bound targets in languages where grep symbol-nav breaks down (typed, overloaded, namespaced); (b) a *zero-install, in-boundary* symbol-nav mechanism becomes available; (c) the bash corpus grows enough that grep precision pain recurs in practice. On any trigger, reopen — starting from the pure-shell helper, not LSP.
- **Follow-up (not built here — scoping spike).** A doc issue to write the word-boundary find-refs idiom into the `planner`/`explorer` multi-site-change guidance. No tooling build.

## Notes

- Spike issue: #426. Gates: issue-reviewer (ship), activation-reviewer (pass).
- Surveyed: 53 `.sh` / ~91 functions; no `.mcp.json`; platform `ctags` is BSD (weak bash support); `.claude/eng-state/` (gitignored, in-boundary) as candidate index storage.
- Distinct from #422/`/recall` (decision record — issues/PRs/ADRs — not code symbols). Distinct from ADR-0002 (#424, generation-side fill) and ADR-0003 (#425, tracing/eval).
- Related: MISSION "The mechanism" (selective injection — low-noise); MISSION isolation model + CLAUDE.md Boundary (no user-global state); SPEC §6.0 (cost-asymmetry).
