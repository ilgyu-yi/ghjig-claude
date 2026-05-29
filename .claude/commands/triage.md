---
description: Deprecated alias for /activate (one release cycle, #173). Delegates the status:proposed substantive gate to /activate; raw-filing needs-triage classification is Phase-2 (not subsumed). Stale-discussion surfacing moved to /activate batch mode.
argument-hint: "[<issue-#>]"
---

**Deprecation alias (SPEC §5.18, retired by #173 under Directive #167).** `/triage` is a thin alias for **`/activate`**, retained for one release cycle. It will be removed in a later terminal Issue.

## What `/activate` covers — and the Phase-2 gap (read this)

`/triage` historically did two things; under #167 they split:

1. **`status:proposed` substantive gate** (Directive proposals + — under full symmetry — Execution Issues) → **fully subsumed by `/activate`** (`.claude/commands/activate.md`). `activation-reviewer` (SPEC §4.9) emits `pass`/`revise`/`reject`; the type-mismatch matrix absorbs the old template-shape classification.
2. **`needs-triage` raw-filing classification** (label-free external filings auto-tagged by `auto-needs-triage.yml`) → **NOT subsumed.** `/activate` only scans `status:proposed`. Reclassifying raw `needs-triage` filings is **Phase-2 external-inbound scope** (Directive #167 non-goal) and is not yet built. Do not imply `/activate` triages raw filings.

The **stale-discussion surface** (open `discussion` Issues > 14 days) moved into `/activate` batch mode (no-arg).

## Procedure

Delegate to `/activate` and apply its result verbatim:
- `/triage <N>` → run `/activate <N>`.
- `/triage` (no arg) → run `/activate` (batch over open `status:proposed` Issues + the stale-discussion surface).

Emit a one-line deprecation notice on use:

```
/triage is a deprecated alias for /activate (one release cycle, #173). Prefer /activate.
Note: raw `needs-triage` filing classification is Phase-2 — /activate handles status:proposed only.
```

There is no behavior unique to this command beyond the delegation + the Phase-2 caveat above — see `.claude/commands/activate.md` for the full procedure, verdict dispatch, filer-aware handling, escape hatch, and forbidden list.
