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
7.5. **PR-body checklist audit** — re-fetch the PR body and scan for any `- [ ]` line. Per SPEC §1.4, a merged PR body must reflect truth: each unchecked item is in one of three terminal states — ticked (`- [x]`) because it was done, marked `- [~] N/A — <one-line reason>` because it intentionally won't be done, or removed from the body. Apply to every checklist (Plan, Test plan, Docs touched, Ship gate). If any `- [ ]` remains after the pass, stop and ask the user — do NOT proceed to `gh pr ready`.
7.6. **Issue AC closeout** — for every issue in the PR's `closingIssuesReferences` (gh's authoritative list of issues that will be auto-closed by merge), run `"$CLAUDE_ENG_SHELL_ROOT/scripts/ac_closeout.sh" "$PR"` to post the canonical `## AC closeout (resolved by PR #N)` comment with each AC ticked or `[~] N/A`'d. The helper is idempotent — it checks each issue's comments for an existing `^## AC closeout` header and skips that issue if found. The PreToolUse `ac-closeout` gate (SPEC §6.1) blocks `gh pr merge` when this step is missing, so running it here satisfies the merge gate by construction. The PR-body checklist (7.5) and the per-issue AC closeout (7.6) together mirror what SPEC §1.4 names "PR-as-living-doc" — symmetric on both sides of the `Closes #N` linkage.
7.7. **Changelog gate** (SPEC §5.7 step 7.7 / §18.7) — the §18.1 fragment contract (CI-enforced per §18.6) must be satisfied **before** ready, not after a red CI check. Require exactly one of: a fragment exists under `changelog_unreleased/<category>/<N>.md` for an allow-set number (the PR number ∪ its `closingIssuesReferences`, the same set `check-changelog.yml` computes), **or** the `skip-changelog` label is present on the PR. This is a **presence** check — fragment *shape* stays CI's job (§18.5), not re-validated here. If neither holds, invoke `/changelog` to author the fragment or apply the label: `attended` proposes the decision for confirmation, `unattended` decides automatically (§5.7.1). Do NOT proceed to `gh pr ready` until the gate holds. The skip decision follows §18.7.
8. `gh pr ready` — draft → ready. Then `gh pr checks --watch` in background; return immediately.
9. If mode is `attended`: stop here and report (existing behavior — human picks up review and merge).
10. If mode is `unattended`: classify the PR state via `ship_classify_blocker` (also in `ship_mode.sh`). Branch per SPEC §5.7.1:
    - `clean` → `gh pr merge --auto --merge --delete-branch`. No-fast-forward merge commit; PR branch commits stay on `main` (preserves the Doc → Test → Code arc per SPEC §1.2). If auto-merge is disabled at the repo level, fall back to the park path with reason `auto-merge-disabled`.
    - `soft` → one self-fix-and-push attempt (commit `fix(#N): ...`), then return to CI-wait. A second `soft` outcome escalates to `hard`.
    - `hard` → park: `gh pr comment` (deterministic state summary) + apply label `unattended-parked` (create on demand; idempotent — edit-last or skip if already labeled) + append one line to `$CLAUDE_ENG_SHELL_ROOT/.claude/state/unattended-park.log` + stop.
10.5. **Directive-aware audit** (added by tracking #41 child #6; SPEC §5.7 dir-mode integration) — informational only; does NOT auto-mark the parent Directive `Completed`. **Canonical hook-enforced path**: `.github/workflows/dir-mode-post-merge.yml` (Directive #61) fires on every `pull_request.closed && merged == true` event regardless of who merged. The Markdown procedure below remains valid for Claude-in-loop runs (defense in depth); the two paths dedupe on the `reflect-stub`/`reflect-enriched` content markers (not the shared PR URL), so a Claude-in-loop `/reflect` enriches the workflow's stub in place rather than no-op'ing against it (SPEC §5.15, #329). Runs on a successful merge (step 10 `clean` branch only — not `soft` or `hard`):
    - For each issue in the merged PR's `closingIssuesReferences`, read the issue body and look for the regex `^Parent Directive: #(\d+)$`. If a match is found, capture the directive number `<D>`.
    - For each `<D>`, append one audit line:
      ```
      audit_log info directive-exec-count merged "directive=#<D> pr=#<PR> issue=#<N>"
      ```
    - **Critical**: this step does NOT flip the Directive's `Status` field. Directives complete via `/complete-directive` + `activation-reviewer` (SPEC §4.9 / §5.13) only. The audit line is a forensic trail of progress toward the Directive's success signals; counting it as completion would violate tracking #41 principle #3 ("Generation is open, decision is gated"). The human-readable counterpart is `/reflect` (SPEC §5.15) — `/ship` records the bare audit; `/reflect` posts the reflection comment on the parent Directive.
11. Emit a single summary line to stdout naming the terminal action taken: `stopped at ready`, `merged`, or `parked: <reason>`.

At the end, print the PR URL and follow-up notes (reviewer mentions, etc.).

## Work language
Author the **curated PR body** (and any commit you push) in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the task context into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`.
