---
description: Query the audit log. Recent blocks, escapes, warns.
argument-hint: [<filter>]
---

Query the audit log at the shared resolution: `source .claude/ghjig-root/scripts/lib/audit_log_path.sh && resolve_audit_log` (§3.2.2).
Floor note: the legacy shared `.claude/ghjig-root/.claude/audit/audit.jsonl` is a read-only floor the resolution consults only when the per-project file is absent — never query it directly in preference to the resolved path.

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
