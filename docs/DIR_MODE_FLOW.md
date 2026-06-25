# Dir-mode Flow

Full details in [SPEC.md §1.7](../SPEC.md) and [SPEC.md §2.1](../SPEC.md). This page sits alongside [`ENGINEERING_FLOW.md`](./ENGINEERING_FLOW.md) — dir-mode is the directional tier above engineering work. The full artifact hierarchy is:

```
Initiative Issue  (optional planning tier — shell consumes, never authors)
   └── Directive Issue   (MISSION-scoped direction; reviewer-gated)
          └── Execution Issue   (one unit of engineering work)
                 └── PR → commits
```

The two flows share the same hooks, audit log, reviewer-pattern, and substrate; the difference is which artifact a given command operates on. The canonical hierarchy diagram is **SPEC §1.7** and the canonical Directive **state machine** (Proposed → Active → Blocked → Completed, with the transition-triggering commands) is **SPEC §2.1** — this page does not redraw them, to keep one diagram per fact rather than two that drift independently.

## The Initiative tier

An **Initiative** is a higher planning artifact (a roadmap, an RFC, a multi-Directive epic) that the shell **consumes, not authors**. Initiative Issues carry the `initiative` label and are **read-only to the shell** — it never edits, closes, or reopens them; it only reads them and posts comments.

- `/consume-initiative <N>` (§5.21) — reads Initiative Issue #N and extracts one or more proposed Directives from it, each reviewer-gated by `activation-reviewer` and filed with a `Parent Initiative: #N` body marker.
- `/initiative-feedback <N>` (§5.22) — posts a structured comment back to the Initiative (extraction summary, open questions) without mutating the Issue.

The `initiative-readonly` hook matcher blocks `gh issue edit/close/reopen` on an `initiative`-labelled Issue (comments are allowed). The `label-parent-consistency` matcher enforces `initiative`/`directive` mutual-exclusivity and the Directive parent-XOR (`## MISSION fit` field XOR a `Parent Initiative: #N` marker). See SPEC §1.7 + §6.1.

## Skill summary

| Skill | What it does | Reviewer | Status transition |
|-------|--------------|----------|-------------------|
| `/consume-initiative <N>` | Extract Directives from an Initiative Issue | `activation-reviewer` (per extracted Directive) | files Proposed Directive(s) |
| `/initiative-feedback <N>` | Post structured feedback comment to an Initiative | — (read-only) | — |
| `/file-directive` | File a new Directive Issue | `activation-reviewer` (filing body) | none → Proposed |
| `/list-directives [--status <S>]` | List Directives filtered by Status label | — | read-only |
| `/activate [<N>]` | Promote any Proposed Issue → Active (single or batch); also surfaces stale discussions | `activation-reviewer` (current body) | Proposed → Active |
| `/triage` | Deprecated one-cycle alias for `/activate` (#173) | — (delegates) | (alias) |
| `/activate-directive <N>` | Deprecated one-cycle alias for `/activate` (#172) | `activation-reviewer` (via `/activate`) | Proposed → Active |
| `/file-issue --parent <N> <description>` | File an Execution Issue under Directive #N | `issue-reviewer` (rationale triad) | — |
| `/link-directive <directive-#> <execution-#>` | Set/repair the `Parent Directive: #N` body marker | — (idempotent) | — |
| `/block-directive <N> --reason '<why>'` | Annotation-only block | — (no body change) | Active → Blocked |
| `/revise-directive <N>` | Replace Directive body in place | `activation-reviewer` (new body) | (no Status flip) |
| `/complete-directive <N>` | Close Directive as Completed | `activation-reviewer` (evidence sufficiency) | Active → Completed |
| `/reflect [<pr-#>]` | Post per-signal reflection on parent Directive | — (marker-keyed: enriches the workflow stub in place; no-op once enriched, #329) | — |

## Operating mode coupling

Per SPEC §1.5 / §5.7.1, every reviewer above gates differently by mode:

- **`attended`** (default) — reviewer verdict surfaces to the human, who decides.
- **`unattended`** — verdict gates directly. `pass` proceeds, `revise` re-routes (the reviewer self-escalates to `reject` after N=3 `revise` markers — the contract SSOT is `.claude/agents/activation-reviewer.md`), `reject` parks the work to the relevant log (`.claude/state/directive-block.log` for /file-directive, `.claude/state/unattended-park.log` for /ship's hard-block).

## Filer-aware invariants

Independent of mode (SPEC §1.5 filer-aware invariants):

- **AI never auto-closes-as-not-planned on a trusted-filer Issue.** Closing with `--reason completed` is allowed (evidence-backed); other close reasons require human confirm.
- **Removing the `directive` label declassifies a Directive — human confirm required always.** The label is the type-awareness key; silently dropping it would bypass dir-mode review.

Both invariants are enforced by the `trusted-filer-mutate` hook matcher.

## Type-aware engineering hooks

Engineering-flow matchers are type-aware:

- AC-closeout matcher skips when ALL closing issues are Directives (Directives close via `/complete-directive`, not AC checkboxes).
- `proposed-protect` matcher blocks `git checkout -b <user>/<type>/<N>-<slug>` when `<N>` is `status:proposed` (any type — run `/activate <N>` first) or a Directive (any status — the engineering-flow `/work-on` is the wrong tool for a Directive; use `/file-issue --parent <N>`).
- `initiative-readonly` matcher blocks mutating `gh issue` subcommands against an `initiative` Issue; `label-parent-consistency` enforces the Initiative/Directive label and parent-marker invariants.
- `directive-close` matcher blocks a GitHub close keyword + Directive `#N` in a `gh pr create`/`edit --body` or a commit message — the auto-close would bypass `/complete-directive` (Execution Issues are unaffected; per-`#N` fail-open).

See SPEC §1.7 type-aware engineering hooks for the predicates (`is_directive_issue`, `is_proposed_issue`, `is_initiative_issue`, `issue_has_*_marker`) and fail-policy.

## Three-tier substrate

A target repo adopts the shell at one of three tiers (SPEC §1.7 substrate-in-target):

- **Tier 1** — eng-mode works without any dir-mode substrate. No `/file-directive`.
- **Tier 2** — Tier 1 + the dir-mode label set installed (see SPEC §1.7 for the authoritative label roster). Unlocks `/file-directive`, `/activate`, `/complete-directive`, etc., writing to Issues directly.
- **Tier 3** — Tier 2 + Issue templates + workflows + Project. Unlocks the Project-as-derived-view and the dir-mode-post-merge auto-reflection. (`/triage` is a deprecated alias for `/activate` as of #173.)

`/onboard-dir-mode` installs each tier via a PR to the target. Substrate failures fail-open per command (graceful-degradation principle, SPEC §1.7).

## See also

- [`ENGINEERING_FLOW.md`](./ENGINEERING_FLOW.md) — the engineering tier (Execution Issue → PR → merge).
- [`SUBAGENTS.md`](./SUBAGENTS.md) — full reviewer catalog including `activation-reviewer` (the triage classifier was retired in #173).
- [`ESCAPE_HATCH.md`](./ESCAPE_HATCH.md) — bypass categories including `directive-review`, `proposed-protect`, `trusted-filer-mutate`, `initiative-readonly`.
- [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) — symptom-to-fix rows for dir-mode blocks.
- [SPEC §1.7, §2.1, §4.9, §5.10–§5.22](../SPEC.md) — full normative spec.
