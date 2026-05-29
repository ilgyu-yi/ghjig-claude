---
description: Alias for /activate <issue-#> (one release cycle). Activates a Proposed Directive — delegates to the polymorphic /activate skill, which runs activation-reviewer and removes status:proposed on pass.
argument-hint: <issue-#>
---

**Deprecation alias (SPEC §5.12).** `/activate-directive <issue-#>` is a thin alias for **`/activate <issue-#>`**, retained for one release cycle for Directive-only muscle memory. It will be removed in a later terminal Issue under Directive #167.

## Procedure

Delegate to `/activate <issue-#>` (`.claude/commands/activate.md`) and apply its result verbatim. `/activate` is type-neutral: for a Directive Issue it runs `activation-reviewer` (SPEC §4.9) on the current body and, on `pass`, removes the `status:proposed` label (→ Active); `revise`/`reject` are handled per the `/activate` filer-aware contract. Audit category: `activation` (generalized from the former `directive-activate`).

Emit a one-line deprecation notice on use:

```
/activate-directive is an alias for /activate (one release cycle). Prefer /activate <issue-#>.
```

There is no behavior unique to this command — see `.claude/commands/activate.md` for the full procedure, verdict dispatch, escape hatch, and forbidden list.
