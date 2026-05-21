---
description: One-shot summary of current work state.
---

Source `$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/status.sh` and call `status_compact`. That helper is the canonical implementation — the `UserPromptSubmit` hook delegates to the same function, so the per-turn summary and the on-demand `/status` block never drift. See SPEC §5.5.

Compact-mode output (one line each, `-` for missing):

- `branch:` current branch + dirty flag
- `issue:` # and title — extracted from `Closes #N` / `Refs #N` in the PR body
- `pr:` # and draft/ready state, plus `[x/y tasks]` checklist progress, plus CI status
- `phase:` inferred from the next unchecked checklist item (Doc / Test / Code / Review / Ship)
- `next:` first unchecked checklist item
- `mode:` attended / unattended via `ship_mode.sh::resolve_mode`

For diff-friendly machine output: `status_json` instead.
