# claude-eng-shell — Operating Norms

This directory holds shell assets injected by claude-eng-shell. This file is a summary of the work norms the shell enforces. Full spec is in the shell repo's `SPEC.md` — consult its **Table of contents** at the top first, then `Read --offset --limit` the targeted section rather than loading the whole 73KB file. Regenerate the TOC via `scripts/build_toc.sh` after editing any SPEC heading.

## Backbone: GitHub standard flow
issue → branch → draft PR → checklist commits → ready PR → merge. Every change rides this flow. No fork (upstream-only).

PR-ready is the autonomy ceiling **by default** (`attended` mode). The `unattended` opt-in deliberately **extends** the ceiling past PR-ready, continuing through the `/ship` CI-wait → merge-or-park terminal step (`gh pr merge` on a clean PR, park on a hard blocker). So under `unattended`, merging a clean PR is *inside* the ceiling, not above it — authority and full contract are SPEC §5.7.1.

**Dir-mode** (SPEC §1.7) extends the same pattern one level up: `MISSION.md` → Directive Issue → Execution Issue. Same generate → review → gated → audit shape; reviewer is `activation-reviewer` (§4.9). Workflow selection between eng-mode and dir-mode is manual; an automatic selector is a deferred capability (SPEC §0.4). Dir-mode commands live in §5.10–§5.18.

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
| Quality check on a proposed Directive or completion claim | `activation-reviewer` (dir-mode, §4.9) |

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
- force push allowed **only to an explicitly-named non-protected branch** (`git push --force-with-lease origin <branch>` — the rebase-pull tail, SPEC §13); a force-push naming a protected branch, OR a **bare/remote-only force-push** (no target named), is blocked — the bare form's true target isn't verifiable (it's config-dependent), so the block message tells you to name the branch. `--amend` (after push) and `--no-verify` blocked
- Secret patterns in staged diff blocked; hits emit `file:line: <id>` for navigation. Path allow-list via `.shellsecretignore` at the target repo root (gitignore-narrow; defaults skip `*test*`, `*example*`, `docs/`, `*.md`)
- `gh pr merge` blocked when a linked issue (via `closingIssuesReferences`) has unchecked AC items and no `^## AC closeout` marker comment yet. Run `scripts/ac_closeout.sh <pr-num>` to satisfy (idempotent — `/ship` step 7.6 invokes it automatically). Escape: `SKIP_HOOKS=ac-closeout SKIP_REASON='<why>'`.
- Edits to `.env`, `*.pem`, `credentials*` blocked
- Edit/Write outside registry, and `rm`/`mv`/`cp` carrying a force/recursive flag in any form (`-rf`, `-r -f`, `--force`, `--recursive`, `-i -rf`; #212) with out-of-registry args, blocked. Two carve-outs: `$CLAUDE_ENG_SHELL_ROOT/` (shell self-modification) and `$HOME/.claude/` (user-global auto-memory tier, issue #91) — both skip the branch + out-of-scope checks. The sensitive-file check (`.env`, `*.pem`, `credentials*`) still fires under both carve-outs.
- SessionStart surfaces silent-no-op states via two once-per-session banners (SPEC §6.5(c)): shell injected but `CLAUDE_ENG_SHELL_ROOT` unset, OR `CLAUDE_ENG_SHELL_ROOT` set but `.claude/hooks/hookrt.sh` missing — each case evaporates hook enforcement; banners surface the actionable fix
- Helper sources — both hook-to-helper (the 5 hook entry-point files) and helper-to-helper (helpers sourcing siblings under `helpers/`) — go through `safe_source <path> <category>` (in `.claude/hooks/hookrt.sh`). A missing helper file fails-open with `audit_log warn <category> helper-missing` — see SPEC §6.1 fail-policy table for per-helper categories. Mitigation for the session-restart caveat on new helpers. Documented exception: the bootstrap-to-runtime shim `helpers/log.sh` → `hookrt.sh` (chicken-and-egg)
- Every matcher in `pre_tool_use.sh` reaches a decided state per fire. Terminal arms emit one audit record (block/warn/`pass-through`); high-frequency happy paths call `mark_allow <cat>` (silent — no audit record). Silent fall-through without `mark_allow` is the regression `pass_through_trace <cat> "<cmd>"` catches (SPEC §6.1 pass-through invariant)
- **Type-aware engineering hooks** (SPEC §1.7, §6.1): `helpers/issue_type.sh` predicates `is_directive_issue <N>` (identifies Directive Issues by the `directive` label; caches per-session under `.claude/state/issue-type-cache/`) and `is_proposed_issue <N>` (identifies `status:proposed` Issues; **uncached** — the label is volatile under `/activate`). AC-closeout matcher skips when ALL closing issues are Directives (Directives close via `/complete-directive`, not AC checkboxes). The `proposed-protect` matcher (generalized from `directive-protect` by #171) blocks `git checkout -b <user>/<type>/<N>-<slug>` when `<N>` is **either** `status:proposed` (any type — redirect names `/activate <N>`) **or** a Directive (any status — Directives never branch; redirect names `/file-issue --parent <N>`). Subsumes, not replaces, the old Directive check (a status-only check would let an Active Directive branch — a §10.5 regression). Fail-open if a predicate cannot resolve (gh down, no auth, undefined). Escape: `SKIP_HOOKS=proposed-protect SKIP_REASON='<why>'`.
- **Filer-aware invariants** (SPEC §1.5, §6.1; added by Directive #92 / Issue #95): `helpers/issue_filer.sh` predicate `is_trusted_filer <N>` checks GitHub's `authorAssociation` (`OWNER`/`MEMBER`/`MAINTAINER`/`COLLABORATOR` = trusted). New `trusted-filer-mutate` matcher blocks two cases: (a) `gh issue close <N>` on a trusted-filer Issue without `--reason completed`; (b) `gh issue edit <N> --remove-label directive` on ANY filer (declassify protection). Mode-independent — applies in both `attended` and `unattended`. Fail-open on helper miss. Escape: `SKIP_HOOKS=trusted-filer-mutate SKIP_REASON='<why>'`.
- **Label↔parent-marker consistency** (SPEC §6.1; Issue #199, enforcing #197's advisory layer): `helpers/issue_type.sh` predicate `issue_has_parent_marker <N>` (uncached — the marker is volatile via `/link-directive` + relabels) resolves the body's line-1 marker, and the `label-parent-consistency` matcher blocks `gh issue edit <N> --add-label {execution|task|bug}` when the label contradicts the Issue body's line-1 `Parent Directive: #N` marker — `execution` with **no** marker (execution Issues require a parent), or `task`/`bug` **with** a marker (standalone types must not be parented; the marker is a type smell). Scoped to the `--add-label` edit path only (the `gh issue create` path is already consistent via `/file-issue`). Converts #197's reviewer/skill prose into runtime enforcement (hooks-as-environment). Fail-open if the Issue body can't be resolved. Escape: `SKIP_HOOKS=label-parent-consistency SKIP_REASON='<why>'`.

Escape (two forms; both audit-logged). **In-harness** (the live Bash tool consumes a leading `VAR=` env-prefix before the hook sees it, so use the trailing sentinel): `<command>  # claude-eng:skip=<category> reason=<reason>`. **Leading env-prefix** (real shell / smoke harness, where it arrives in the command string): `SKIP_HOOKS=<category> SKIP_REASON='<reason>' <command>`. Leading wins if both present. The trailing sentinel is honored only when its `#` is a genuine unquoted comment token — a `#` inside a quoted argument is argument text, not an escape, and never disarms a matcher (#208). Full contract: SPEC §7.

## Boundary
- The shell never touches user-global state (`~/.zshrc`, `~/.claude`, global git config, etc.).
- The shell only operates within paths registered in the registry.
