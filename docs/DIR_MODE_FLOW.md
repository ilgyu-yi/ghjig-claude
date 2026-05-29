# Dir-mode Flow

Full details in [SPEC.md §1.7](../SPEC.md) and [SPEC.md §2.1](../SPEC.md). This page sits alongside [`ENGINEERING_FLOW.md`](./ENGINEERING_FLOW.md) — dir-mode is the directional tier above engineering work: `MISSION.md` → Directive Issue → Execution Issue → PR. The two flows share the same hooks, audit log, reviewer-pattern, and substrate; the difference is which artifact a given command operates on.

```
[Strategic direction surfaces — friction, repeated questions, multi-week scope]
       │
       ▼
  /file-directive             ← reviewer-gated authoring against MISSION.md
       │   AI drafts body from .claude/templates/directive.md
       │   activation-reviewer (§4.9.1) checks schema + scope + MISSION fit + active-Directive conflict
       │   verdict: ship → Issue filed with labels [directive, status:proposed]
       │            refine → revise body, re-route reviewer
       │            block → park to .claude/state/directive-block.log
       ▼
[Directive in `Proposed` state]   visible via /list-directives --status Proposed
       │
       ├── /triage (maintainer queue)        ← triage-reviewer (§4.10) binary ACCEPT/REJECT
       │       REJECT → close-as-not-planned + maintainer refiles in correct template
       │       ACCEPT → continue
       │
       ▼
  /activate-directive <N>     ← activation-reviewer re-runs on current body (catches GH-UI edits)
       │   verdict: ship → status:proposed label removed → Directive becomes `Active`
       │            refine/block → label stays
       ▼
[Directive in `Active` state]    visible via /list-directives (default omits Completed)
       │
       │   ── execution loop ──
       │
       ├── /file-issue --parent <N> <description>
       │       │   issue-reviewer (§4.7) rationale-triad check
       │       │   on ship → Execution Issue filed with body marker `Parent Directive: #<N>`
       │       │   /link-directive <N> <execution-#> is idempotent for re-linking
       │       ▼
       │   /work-on <execution-#>           ← planner + plan-reviewer per ENGINEERING_FLOW.md
       │       │                              (Doc → Test → Code per CLAUDE.md §1.2)
       │       ▼
       │   /ship                            ← code-reviewer + AC closeout + ready + merge
       │       │   on merge: dir-mode-post-merge.yml workflow posts a reflection
       │       │   comment on Directive #<N> via /reflect (idempotent on URL match)
       │       ▼
       │   [Execution Issue closed]         → counts toward Directive's success signals
       │
       ├── /block-directive <N> --reason '<why>'   ← annotation-only; not reviewer-gated
       │       │   adds status:blocked label + ## Blocked comment
       │       │   Directive stays open; unblock via /activate-directive (re-runs reviewer)
       │       ▼
       │   [Directive in `Blocked` state]
       │
       ├── /revise-directive <N>            ← scope/success-signal change
       │       │   activation-reviewer on the NEW body (same five checks as /file-directive)
       │       │   on ship → prior body archived as comment + body replaced
       │       │   NO status change — audit-log entry + archive comment ARE the evidence
       │
       ▼   (after all Execution Issues for this Directive have merged)
  /complete-directive <N>     ← activation-reviewer evaluates evidence-sufficiency
       │   reviewer reads Directive's success signals + linked Execution Issues' close states + AC ticks
       │   verdict: ship  → closing comment posted (per-signal evidence) + Issue closes --reason completed
       │            refine → "need engineering evidence" — file more work first
       │            block  → Directive stays Active
       ▼
[Directive in `Completed` state]   visible via /list-directives --status Completed
```

## Skill summary

| Skill | What it does | Reviewer | Status transition |
|-------|--------------|----------|-------------------|
| `/file-directive` | File a new Directive Issue | `activation-reviewer` (filing body) | none → Proposed |
| `/list-directives [--status <S>]` | List Directives filtered by Status label | — | read-only |
| `/triage` | Per-Issue ACCEPT/REJECT classifier (covers `needs-triage` and `status:proposed`) | `triage-reviewer` | (no body change) |
| `/activate-directive <N>` | Promote Proposed → Active | `activation-reviewer` (current body re-check) | Proposed → Active |
| `/file-issue --parent <N> <description>` | File an Execution Issue under Directive #N | `issue-reviewer` (rationale triad) | — |
| `/link-directive <directive-#> <execution-#>` | Set/repair the `Parent Directive: #N` body marker | — (idempotent) | — |
| `/block-directive <N> --reason '<why>'` | Annotation-only block | — (no body change) | Active → Blocked |
| `/revise-directive <N>` | Replace Directive body in place | `activation-reviewer` (new body) | (no Status flip) |
| `/complete-directive <N>` | Close Directive as Completed | `activation-reviewer` (evidence sufficiency) | Active → Completed |
| `/reflect [<pr-#>]` | Post per-signal reflection on parent Directive | — (idempotent on URL match) | — |

## Operating mode coupling

Per SPEC §1.5 / §5.7.1, every reviewer above gates differently by mode:

- **`attended`** (default) — reviewer verdict surfaces to the human, who decides.
- **`unattended`** — verdict gates directly. `ship` proceeds, `refine` re-routes (with two-refine escalation), `block` parks the work to the relevant log (`.claude/state/directive-block.log` for /file-directive, `.claude/state/unattended-park.log` for /ship's hard-block).

## Filer-aware invariants

Independent of mode (SPEC §1.5 filer-aware invariants):

- **AI never auto-closes-as-not-planned on a trusted-filer Issue.** Closing with `--reason completed` is allowed (evidence-backed); other close reasons require human confirm.
- **Removing the `directive` label declassifies a Directive — human confirm required always.** The label is the type-awareness key; silently dropping it would bypass dir-mode review.

Both invariants are enforced by the `trusted-filer-mutate` hook matcher.

## Type-aware engineering hooks

Engineering-flow matchers skip Directive Issues:

- AC-closeout matcher skips when ALL closing issues are Directives (Directives close via `/complete-directive`, not AC checkboxes).
- `directive-protect` matcher blocks `git checkout -b <user>/<type>/<N>-<slug>` when `<N>` is a Directive — the engineering-flow `/work-on` is the wrong tool for a Directive.

See SPEC §1.7 type-aware engineering hooks for the predicate (`is_directive_issue`) and fail-policy.

## Three-tier substrate

A target repo adopts the shell at one of three tiers (SPEC §1.7 substrate-in-target):

- **Tier 1** — eng-mode works without any dir-mode substrate. No `/file-directive`.
- **Tier 2** — Tier 1 + the 10-label dir-mode set installed. Unlocks `/file-directive`, `/activate-directive`, `/complete-directive`, etc., writing to Issues directly.
- **Tier 3** — Tier 2 + Issue templates + workflows + Project. Unlocks `/triage`, the Project-as-derived-view, and the dir-mode-post-merge auto-reflection.

`/onboard-dir-mode` installs each tier via a PR to the target. Substrate failures fail-open per command (graceful-degradation principle, SPEC §1.7).

## See also

- [`ENGINEERING_FLOW.md`](./ENGINEERING_FLOW.md) — the engineering tier (Execution Issue → PR → merge).
- [`SUBAGENTS.md`](./SUBAGENTS.md) — full reviewer catalog including `activation-reviewer` and `triage-reviewer`.
- [`ESCAPE_HATCH.md`](./ESCAPE_HATCH.md) — bypass categories including `directive-review`, `directive-protect`, `trusted-filer-mutate`.
- [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) — symptom-to-fix rows for dir-mode blocks.
- [SPEC §1.7, §2.1, §4.9, §5.10–§5.18](../SPEC.md) — full normative spec.
