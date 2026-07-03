---
description: Compare the working diff against the Plan; re-invoke planner only on STRUCTURAL divergence (out-of-plan load-bearing files or an unreachable AC). Advisory, not a gate.
---

Source `.claude/ghjig-root/.claude/hooks/helpers/replan_check.sh` and call `replan_check_facts`. That helper surfaces the mechanical facts (base, touched files, PR-body Plan/Checklist/Key-context/Out-of-scope, linked-issue ACs) — fail-open. A touched file the Plan declared **out-of-scope** is a strong structural signal. The **judgment** below is yours (LLM). See SPEC §5.26.

Read the facts, then classify the divergence:

**Structural → re-invoke `planner`** (mirror `/work-on` step 6; in `unattended`, a clean `plan-reviewer` re-substitutes for approval) if EITHER:
- the diff touches a **load-bearing** file/area the Plan / Checklist / Key-context never anticipated (a new module, a schema/contract surface, an un-named subsystem) — *not* a mechanical incidental; OR
- an **AC is rendered unreachable** — the approach taken closes off a path a linked-issue acceptance criterion required.

**Cosmetic → no re-plan** (emit a one-line advisory at most): files that are the **direct mechanical consequence** of a planned change (a regenerated TOC, a changelog fragment, the SSOT-coupling the Plan already implies — e.g. a §8 tree bump for a planned helper), in-scope reordering/renaming, or any change that leaves every AC reachable.

The threshold is **asymmetric** (SPEC §6.0): re-invoking `planner` is expensive and this judgment is fallible, so **fail toward not-triggering** — when in doubt, emit the advisory, do not re-plan. This is a **positive advisory checkpoint, not a hard gate**; never block a commit on it.

On a structural verdict, after `planner` re-runs (and `plan-reviewer` clears it), curate the PR body via `/sync-pr` so the Plan reflects the new reality.
