---
description: Update the current PR body to match commit history and local intent. Aborts on external-edit conflict.
---

Update the PR body. External-edit detection is real and persistent — see SPEC §5.4.

1. Get current PR number: `gh pr view --json number --jq .number`. None → stop.
2. Refetch remote body: `gh pr view --json body --jq .body`.
3. Source `.claude/ghjig-root/.claude/hooks/helpers/pr_cache.sh` and call `pr_cache_check <pr_number> <remote_body_sha256>`. If it exits non-zero (external edit detected), report the conflict to the user and abort.
3.4. **Claim ordering** (SPEC §1.11 L2/L5) — while the body is still yours to edit, take each descriptive fact in L5's order: **delete** it (the default — a claim the body does not need is removed, not sourced); else reduce it to a **pointer** (issue #, path, sha, § heading); only a residue that must appear as a figure is **rendered** via `bash .claude/ghjig-root/scripts/ghjig_evidence.sh evidence '<command>'` — the last rung's instrument, never the step's opening move. Advisory like the citation step below: it gates nothing and changes no reviewer verdict.

3.5. Before the `gh …` call that writes the body, run `bash .claude/ghjig-root/scripts/lint_citations.sh <body-file>` and surface its report — the stdout findings **and** the stderr `citation note` lines, since a report relayed without them reads as though the whole body was examined when it was not. It decides the lexical half of SPEC §1.10 part (a); it exits 0 always, gates nothing, and a finding is never a refusal to write (SPEC §1.10, §5.2). The body here is the **new** one, and this runs after step 3's abort so a doomed edit pays no cost; `mkdir -p .claude/ghjig-state/tmp`, stage it to `.claude/ghjig-state/tmp/proposed-pr-edit-body.md` — git-excluded, so it never enters the step-5 sha — and `rm -f` it after the read, since leaving it behind accumulates pre-review drafts on disk indefinitely.
4. If the cache matches (or no cache exists yet), apply intended changes (checklist updates, Decisions additions, etc.) via `gh pr edit --body "..."`.
5. After a successful edit, call `pr_cache_write <pr_number> <new_body_sha256> <current_head_sha>` so the next sync starts from a known-good baseline.
6. Curation principles:
   - Tidy stale items.
   - If history is needed, keep one line per entry in a separate "Changelog" section.
   - Editorial, not append-only.
7. **Post-sync divergence advisory** — after a successful sync, run `/replan-check` (SPEC §5.26): the body was just curated, so it's the natural cadence to compare the Plan against the actual diff and re-invoke `planner` on *structural* divergence. Advisory only — never blocks. Skip if no PR/plan exists yet.
