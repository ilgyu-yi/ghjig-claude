---
description: Update the current PR body to match commit history and local intent. Aborts on external-edit conflict.
---

Update the PR body. External-edit detection is real and persistent — see SPEC §5.4.

1. Get current PR number: `gh pr view --json number --jq .number`. None → stop.
2. Refetch remote body: `gh pr view --json body --jq .body`.
3. Source `.claude/ghjig-root/.claude/hooks/helpers/pr_cache.sh` and call `pr_cache_check <pr_number> <remote_body_sha256>`. If it exits non-zero (external edit detected), report the conflict to the user and abort.
4. If the cache matches (or no cache exists yet), apply intended changes (checklist updates, Decisions additions, etc.) via `gh pr edit --body "..."`.
5. After a successful edit, call `pr_cache_write <pr_number> <new_body_sha256> <current_head_sha>` so the next sync starts from a known-good baseline.
6. Curation principles:
   - Tidy stale items.
   - If history is needed, keep one line per entry in a separate "Changelog" section.
   - Editorial, not append-only.
7. **Post-sync divergence advisory** — after a successful sync, run `/replan-check` (SPEC §5.26): the body was just curated, so it's the natural cadence to compare the Plan against the actual diff and re-invoke `planner` on *structural* divergence. Advisory only — never blocks. Skip if no PR/plan exists yet.
