---
description: Deprecated alias for /activate (one release cycle, #173). Delegates the status:proposed substantive gate to /activate; raw label-free filings are auto-stamped status:proposed+task by auto-status-proposed.yml (#179) and validated at /activate. Stale-discussion surfacing moved to /activate batch mode.
argument-hint: "[<issue-#>]"
---

**Deprecation alias (SPEC §5.18, retired by #173 under Directive #167).** `/triage` is a thin alias for **`/activate`**, retained for one release cycle. It will be removed in a later terminal Issue.

## What `/activate` covers

`/triage` historically did two things; under #167/#178 both are now handled:

1. **`status:proposed` substantive gate** (Directive proposals + Execution Issues) → **subsumed by `/activate`** (`.claude/commands/activate.md`). `activation-reviewer` (SPEC §4.9) emits `pass`/`revise`/`reject`; the type-mismatch matrix absorbs the old template-shape classification.
2. **Raw / label-free filings** → previously got a dormant raw-filing label awaiting classification. As of #179, the label-free-filing workflow (`auto-status-proposed.yml`) auto-stamps such filings `status:proposed`+`task`, so they enter the same `/activate` gate as every other Issue — there is no separate raw-filing triage step any more.

The **stale-discussion surface** (open `discussion` Issues > 14 days) moved into `/activate` batch mode (no-arg).

## Procedure

Delegate to `/activate` and apply its result verbatim:
- `/triage <N>` → run `/activate <N>`.
- `/triage` (no arg) → run `/activate` (batch over open `status:proposed` Issues + the stale-discussion surface).

Emit a one-line deprecation notice on use:

```
/triage is a deprecated alias for /activate (one release cycle, #173). Prefer /activate.
```

There is no behavior unique to this command beyond the delegation — see `.claude/commands/activate.md` for the full procedure, verdict dispatch, filer-aware handling, escape hatch, and forbidden list.
