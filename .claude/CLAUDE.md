# claude-eng-shell — Operating Norms

This directory holds shell assets injected by claude-eng-shell. This file is a summary of the work norms the shell enforces. Full spec is in the shell repo's `SPEC.md` — consult its **Table of contents** at the top first, then `Read --offset --limit` the targeted section rather than loading the whole 73KB file. Regenerate the TOC via `scripts/build_toc.sh` after editing any SPEC heading.

## Backbone: GitHub standard flow
issue → branch → draft PR → checklist commits → ready PR → merge. Every change rides this flow. No fork (upstream-only).

PR-ready is the autonomy ceiling **by default** (`attended` mode). The `unattended` opt-in deliberately **extends** the ceiling past PR-ready, continuing through the `/ship` CI-wait → merge-or-park terminal step (`gh pr merge` on a clean PR, park on a hard blocker). So under `unattended`, merging a clean PR is *inside* the ceiling, not above it — authority and full contract are SPEC §5.7.1.

**Dir-mode** (SPEC §1.7) extends the same pattern one level up: `MISSION.md` → Directive Issue → Execution Issue. Same generate → review → gated → audit shape; reviewer is `activation-reviewer` (§4.9). Workflow selection between eng-mode and dir-mode is manual; an automatic selector is a deferred capability (SPEC §0.4). Dir-mode commands live in §5.10–§5.22.

An optional **Initiative** tier sits above Directives: a planning artifact the shell **consumes, not authors** (`/consume-initiative` extracts Directives from it; `/initiative-feedback` posts comments back). Initiative Issues are read-only to the shell — see SPEC §1.7 for the full `Initiative → Directive → Execution` hierarchy and the three initiative matchers (`label-parent-consistency` mutual-exclusivity + parent-XOR, `initiative-readonly`) in §6.1.

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

**Working-tree isolation** (SPEC §1.5, #285): the read-only-by-intent subagents (`code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `activation-reviewer`, `explorer`) share the parent's working tree and carry `Bash`, so a tree-mutating git command inside one can silently revert/stage the parent's uncommitted work. Invoke them with **worktree isolation** (canonical); their prompts also constrain them to read-only git. Run `git status` before each commit/merge as the catch-all.

## Branch & commit convention
- Branch: `<gh-username>/<type>/[<issue#>-]<slug>`
- Commit: `<type>(#<issue>)[!]: <subject>` (codepoint 1–72)
- Required group (`feat`/`fix`/`docs`/`refactor`/`perf`) — issue # required
- Optional group (`test`/`style`/`build`/`ci`/`chore`/`revert`) — issue # optional
- `Closes #N` (single/final PR), `Refs #N` (intermediate PR)

## What hooks enforce
- Protected branch direct commit/push blocked. **Stage-0 exception** (SPEC §5.0, §16 item 15): a brand-new target with no default branch (empty repo / unborn HEAD reporting `main`) cannot make its *seed* commit ride a flow that presupposes a prior commit. `/bootstrap-repo` owns this single, scoped, audit-logged bypass via the `branch` escape (trailing-sentinel `# claude-eng:skip=branch reason=stage-0-bootstrap-seed-on-unborn-HEAD`); the gate itself is **not** weakened, and the bypass is recorded in `audit.jsonl`. This generalizes the shell's own-repo first-commit exception to targets.
- force push allowed **only to an explicitly-named non-protected branch** (`git push --force-with-lease origin <branch>` — the rebase-pull tail, SPEC §13); a force-push naming a protected branch, OR a **bare/remote-only force-push** (no target named), is blocked — the bare form's true target isn't verifiable (it's config-dependent), so the block message tells you to name the branch. `--amend` (after push) and `--no-verify` blocked
- Secret patterns in staged diff blocked; hits emit `file:line: <id>` for navigation. Path allow-list via `.shellsecretignore` at the target repo root (gitignore-narrow; defaults skip component-aware test/example globs — `tests/`, `test/`, `*_test.*`, `*.test.*`, `*-test.*`, `*test_*.*`, `examples/`, `example/`, `*-example.*`, `*_example.*`, `*.example.*` — plus `docs/` and `*.md`; see the file for the authoritative set)
- `gh pr merge` blocked when a linked issue (via `closingIssuesReferences`) has unchecked AC items and no `^## AC closeout` marker comment yet. Run `scripts/ac_closeout.sh <pr-num>` to satisfy (idempotent — `/ship` step 7.6 invokes it automatically). Escape: `SKIP_HOOKS=ac-closeout SKIP_REASON='<why>'`.
- `gh pr merge` to the **default branch** blocked unless the strategy is `--merge` (`merge-strategy` matcher, SPEC §5.7.1/§6.1, #288): `--squash`/`--rebase`/a bare merge → blocked (a squash collapses the Doc→Test→Code arc into one commit on `main`); `--merge` (incl. `--auto --merge`, the `/ship` form) → allowed. Squash is **allowed** on a non-default base (topic-branch consolidation, §10.5). Keyed on the live default branch; fail-open if `gh` can't resolve the base/default. Escape: `SKIP_HOOKS=merge-strategy SKIP_REASON='<why>'`.
- Edits to `.env`, `*.pem`, `credentials*` blocked
- Edit/Write outside registry blocked. **The two carve-outs apply to the Edit/Write check only**: `$CLAUDE_ENG_SHELL_ROOT/` (shell self-modification) and `$HOME/.claude/` (user-global auto-memory tier, issue #91) — both skip the branch + out-of-scope checks for Edit/Write. The sensitive-file check (`.env`, `*.pem`, `credentials*`) still fires under both carve-outs.
- Separately, `rm`/`mv`/`cp` carrying a force/recursive flag in any form (`-rf`, `-r -f`, `--force`, `--recursive`, `-i -rf`; #212) with out-of-registry args is blocked. This destructive-command check has **no carve-out** (SPEC §6.1 scopes the carve-outs to the Edit/Write rows only), so a forced `rm`/`mv`/`cp` targeting a path under `$HOME/.claude/` — which is outside the registry — is still blocked; use `SKIP_HOOKS=out-of-scope SKIP_REASON='<why>'` for legitimate cases (e.g. pruning a stale memory file). Paths under `$CLAUDE_ENG_SHELL_ROOT/` are typically inside the registry, so destructive ops there pass the ordinary scope check.
- **Shell-root resolution order** (SPEC §3.2.1; #312, Directive #311): each hook entry script derives its root as `SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-<self-located via BASH_SOURCE + pwd -P>}"`. The env var wins when set (dogfood/wrapper, back-compat); otherwise the hook self-locates. Injected **targets** carry a per-project untracked binding symlink `.claude/eng-shell-root → <canonical shell root>` and a `settings.local.json → shell/.claude/settings.injected.json` symlink whose hook commands use `${CLAUDE_PROJECT_DIR}/.claude/eng-shell-root/.claude/hooks/<e>.sh` — so a plain `claude` in a registered target resolves the shell with **no global env / no `~/.zshrc`**. The shell's own `.claude/settings.json` stays `$CLAUDE_ENG_SHELL_ROOT`-based.
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
