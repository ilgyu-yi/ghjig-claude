---
description: Gate the PR for ready transition — review, tests, doc sync, PR body curation, CI, then gh pr ready.
---

Execute ship steps in order. If any step fails, stop immediately and report.

0. **Resolve mode** via `resolve_mode` from `$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/ship_mode.sh`. Priority: `--mode=` flag → `$CLAUDE_ENG_SHELL_MODE` → `.claude/state/mode` → default `attended`. Unknown values fail closed to `attended` with a stderr warning. See SPEC §5.7.1.
1. Invoke `code-reviewer`. Blocker → stop.
2. If the diff touches a security surface, invoke `security-reviewer`. High/Medium findings → stop.
3. Final SSOT sync check via `doc-writer`. Missing doc updates → stop and ask user.
4. **Run the full test suite** (`$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/tests.sh` → `run_tests`, or `detect_test_cmd` result). Failure → stop.
5. Curate the PR body (tidy stale items, check ship gate). Use `/sync-pr`.
6. Verify `Closes #N` — single/final PR uses `Closes`, intermediate uses `Refs`. Check the first line of the PR body.
7. CI snapshot: `gh pr checks --json state`. `failure`/`cancelled` → stop.
7.5. **Checklist audit** — re-fetch the PR body and scan for any `- [ ]` line. Per SPEC §1.4, a merged PR body must reflect truth: each unchecked item is in one of three terminal states — ticked (`- [x]`) because it was done, marked `- [~] N/A — <one-line reason>` because it intentionally won't be done, or removed from the body. Apply to every checklist (Plan, Test plan, Docs touched, Ship gate). If any `- [ ]` remains after the pass, stop and ask the user — do NOT proceed to `gh pr ready`. Same rule on auto-close for issues: post a closing comment confirming each acceptance-criterion item, ticked or N/A'd.
8. `gh pr ready` — draft → ready. Then `gh pr checks --watch` in background; return immediately.
9. If mode is `attended`: stop here and report (existing behavior — human picks up review and merge).
10. If mode is `unattended`: classify the PR state via `ship_classify_blocker` (also in `ship_mode.sh`). Branch per SPEC §5.7.1:
    - `clean` → `gh pr merge --auto --merge --delete-branch`. No-fast-forward merge commit; PR branch commits stay on `main` (preserves the Doc → Test → Code arc per SPEC §1.2). If auto-merge is disabled at the repo level, fall back to the park path with reason `auto-merge-disabled`.
    - `soft` → one self-fix-and-push attempt (commit `fix(#N): ...`), then return to CI-wait. A second `soft` outcome escalates to `hard`.
    - `hard` → park: `gh pr comment` (deterministic state summary) + apply label `unattended-parked` (create on demand; idempotent — edit-last or skip if already labeled) + append one line to `$CLAUDE_ENG_SHELL_ROOT/.claude/state/unattended-park.log` + stop.
11. Emit a single summary line to stdout naming the terminal action taken: `stopped at ready`, `merged`, or `parked: <reason>`.

At the end, print the PR URL and follow-up notes (reviewer mentions, etc.).
