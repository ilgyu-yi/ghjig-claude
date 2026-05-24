# claude-eng-shell — Operating Norms

This directory holds shell assets injected by claude-eng-shell. This file is a summary of the work norms the shell enforces. Full spec is in the shell repo's `SPEC.md` — consult its **Table of contents** at the top first, then `Read --offset --limit` the targeted section rather than loading the whole 73KB file. Regenerate the TOC via `scripts/build_toc.sh` after editing any SPEC heading.

## Backbone: GitHub standard flow
issue → branch → draft PR → checklist commits → ready PR → merge. Every change rides this flow. No fork (upstream-only).

Default autonomy ceiling stops at PR-ready (`attended` mode). See SPEC §5.7.1 for the `unattended` opt-in.

**Dir-mode** (SPEC §1.7) extends the same pattern one level up: Final Goal → Directive → Execution Issue. Same generate → review → gated → audit shape; reviewer is `directive-reviewer` (§4.9). Mode switching is manual in v0; orchestration is v1+ (§0.4). Dir-mode commands live in §5.10–§5.14.

## Work order: Doc → Test → Code
1. **Doc** — Write the behavior/contract to be changed into the SSOT (MISSION, README, CLAUDE.md, ARCHITECTURE, ADR) first.
2. **Test** — Translate the doc into a failing test. Confirm the intended failure.
3. **Code** — Minimum implementation to pass the test.

Each phase should be its own commit when possible. The commit graph of the PR should show Doc → Test → Code.

Relaxed when: `fix` (reproduce-first), `refactor` (doc skippable if external behavior unchanged), `perf` (measure first), spikes, one-line typos. State the reason in one line in the PR body Plan.

Strict: `feat`, `docs`, external contract / API / schema changes.

## Active SSOT maintenance
Code changes commit with the SSOT items they invalidate or update. If a doc change is intentionally omitted, the commit body says `Docs: n/a — <short reason>`.

## PR-as-living-doc
- The PR body is **editorial**, not append-only. Curate right after each commit.
- Order: **commit → PR body update**. Fact first, then reflection.
- Right before updating, refetch the remote body — if it changed (external edit), abort the auto-update.

## Subagents
| Situation | Agent |
|-----------|-------|
| Wide read-only exploration | `explorer` |
| 3+ file changes, schema/API/migration | `planner` (required) |
| Doc writing / updating | `doc-writer` |
| Test writing (Phase B) | `test-writer` |
| Pre-commit / pre-PR review | `code-reviewer` |
| Auth/input/deps/crypto changes | `security-reviewer` |
| Rationale check on a proposed issue body | `issue-reviewer` |
| Approach / alternatives check on a planner output | `plan-reviewer` |
| Quality check on a proposed Directive or completion claim | `directive-reviewer` (dir-mode, §4.9) |

In `unattended` mode, the reviewers above substitute for human review at their respective checkpoints (SPEC §1.5 operating-mode coupling).

**Session-restart caveat** (SPEC §4.9.3): Claude Code enumerates `subagent_type` values from `.claude/agents/*.md` at session start. A reviewer added mid-session falls back to `general-purpose` routing until the next session restart — file presence is necessary but not sufficient. The fallback is functionally complete (the agent's prompt instructs `general-purpose` to behave as the new reviewer); restart is canonical.

Don't re-run an exploration in `explorer` that the main assistant already did.

## Branch & commit convention
- Branch: `<gh-username>/<type>/[<issue#>-]<slug>`
- Commit: `<type>(#<issue>)[!]: <subject>` (codepoint 1–72)
- Required group (`feat`/`fix`/`docs`/`refactor`/`perf`) — issue # required
- Optional group (`test`/`style`/`build`/`ci`/`chore`/`revert`) — issue # optional
- `Closes #N` (single/final PR), `Refs #N` (intermediate PR)

## What hooks enforce
- Protected branch direct commit/push blocked
- force push, `--amend` (after push), `--no-verify` blocked
- Secret patterns in staged diff blocked; hits emit `file:line: <id>` for navigation. Path allow-list via `.shellsecretignore` at the target repo root (gitignore-narrow; defaults skip `*test*`, `*example*`, `docs/`, `*.md`)
- `gh pr merge` blocked when a linked issue (via `closingIssuesReferences`) has unchecked AC items and no `^## AC closeout` marker comment yet. Run `scripts/ac_closeout.sh <pr-num>` to satisfy (idempotent — `/ship` step 7.6 invokes it automatically). Escape: `SKIP_HOOKS=ac-closeout SKIP_REASON='<why>'`.
- Edits to `.env`, `*.pem`, `credentials*` blocked
- Edit/Write outside registry, and `rm -rf`/`mv -f`/`cp -f` with out-of-registry args, blocked
- SessionStart surfaces silent-no-op states via two once-per-session banners (SPEC §6.5(c)): shell injected but `CLAUDE_ENG_SHELL_ROOT` unset, OR `CLAUDE_ENG_SHELL_ROOT` set but `.claude/hooks/hookrt.sh` missing — each case evaporates hook enforcement; banners surface the actionable fix
- Helper sources — both hook-to-helper (the 5 hook entry-point files) and helper-to-helper (helpers sourcing siblings under `helpers/`) — go through `safe_source <path> <category>` (in `.claude/hooks/hookrt.sh`). A missing helper file fails-open with `audit_log warn <category> helper-missing` — see SPEC §6.1 fail-policy table for per-helper categories. Mitigation for the session-restart caveat on new helpers. Documented exception: the bootstrap-to-runtime shim `helpers/log.sh` → `hookrt.sh` (chicken-and-egg)
- Every matcher in `pre_tool_use.sh` reaches a decided state per fire. Terminal arms emit one audit record (block/warn/`pass-through`); high-frequency happy paths call `mark_allow <cat>` (silent — no audit record). Silent fall-through without `mark_allow` is the regression `pass_through_trace <cat> "<cmd>"` catches (SPEC §6.1 pass-through invariant)
- **Type-aware engineering hooks** (SPEC §1.7, §6.1): `helpers/issue_type.sh` predicate `is_directive_issue <N>` identifies Directive Issues by the `directive` label and caches results per-session under `.claude/state/issue-type-cache/`. AC-closeout matcher skips when ALL closing issues are Directives (Directives close via `/complete-directive`, not AC checkboxes). New `directive-protect` matcher blocks `git checkout -b <user>/<type>/<N>-<slug>` when `<N>` is a Directive; redirect message names `/activate-directive` (Planned) and `/file-issue --parent` (Active). Both fail-open if `is_directive_issue` cannot resolve (gh down, no auth, etc.). Escape: `SKIP_HOOKS=directive-protect SKIP_REASON='<why>'`.

Escape: `SKIP_HOOKS=<category> SKIP_REASON='<reason>' <command>`. All escapes are audit-logged.

## Boundary
- The shell never touches user-global state (`~/.zshrc`, `~/.claude`, global git config, etc.).
- The shell only operates within paths registered in the registry.
