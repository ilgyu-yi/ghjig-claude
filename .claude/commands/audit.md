---
description: Query the audit log. Recent blocks, escapes, warns.
argument-hint: [<filter>]
---

Query `$CLAUDE_ENG_SHELL_ROOT/.claude/audit/audit.jsonl`.

If `$ARGUMENTS` is empty, show the last 50 lines.
With an argument, grep by substring (e.g. `force-push`, `escape`, `2026-05-19`).

Aggregate:
- Escape count per category.
- Most-escaped category — signal for hook tuning.

Format for human readability, one line each: `<ts> <event>/<decision> [<category>] <reason>`.

For §6.0 P3 migration candidates (structured, threshold-based reports over the same log):
- `scripts/narrowing_candidates.sh [<log>]` — escape-clustering (same category/reason across distinct days) → gates that may warrant narrowing.
- `scripts/promotion_candidates.sh [<log>]` — reviewer-reject reason-class aggregation → advisory→hook promotion candidates.

Both are read-only and surfacing-only (they list candidates; the narrow/promote decision stays human/reviewer judgment).
