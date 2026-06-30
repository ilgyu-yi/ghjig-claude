# claude-eng-shell — Operating Norms

This directory holds shell assets injected by claude-eng-shell. This file is a summary of the work norms the shell enforces. Full spec is in the shell repo's `SPEC.md` — consult its **Table of contents** at the top first, then `Read --offset --limit` the targeted section rather than loading the whole 73KB file. Regenerate the TOC via `scripts/build_toc.sh` after editing any SPEC heading.

## Backbone: GitHub standard flow
issue → branch → draft PR → checklist commits → ready PR → merge. Every change rides this flow. No fork (upstream-only).

PR-ready is the autonomy ceiling **by default** (`attended` mode). The `unattended` opt-in deliberately **extends** the ceiling past PR-ready, continuing through the `/ship` CI-wait → merge-or-park terminal step (`gh pr merge` on a clean PR, park on a hard blocker). So under `unattended`, merging a clean PR is *inside* the ceiling, not above it — authority and full contract are SPEC §5.7.1.

**Dir-mode** (SPEC §1.7) extends the same pattern one level up: `MISSION.md` → Directive Issue → Execution Issue. Same generate → review → gated → audit shape; reviewer is `activation-reviewer` (§4.9). Workflow selection between eng-mode and dir-mode is manual; an automatic selector is a deferred capability (SPEC §0.4). Dir-mode commands live in §5.10–§5.22.

An optional **Initiative** tier sits above Directives: a planning artifact the shell **consumes, not authors** (`/consume-initiative` extracts Directives from it; `/initiative-feedback` posts comments back). Initiative Issues are read-only to the shell — see SPEC §1.7 for the full `Initiative → Directive → Execution` hierarchy and the three initiative matchers (`label-parent-consistency` mutual-exclusivity + parent-XOR, `initiative-readonly`) in §6.1.

## Communication language vs work language
The conversation with the human (**communication language**) and the language of durable repo artifacts (**work language**) are separate channels (SPEC §5.7.2, Directive #322). Chat replies stay in the user's language; **all durable artifacts** — commit messages, PR titles/bodies, issue/directive/execution bodies, acceptance criteria, changelog fragments, shell-authored code comments, audit `reason` text — are authored in the **work language**, resolved by `resolve_work_lang` (`.claude/hooks/helpers/work_lang.sh`): `$CLAUDE_ENG_WORK_LANG` → `.claude/state/work-lang` (cwd-relative) → default `en`. Any language code is accepted (not ko/en-hardcoded). **Before authoring any artifact** (after the conversation concludes), recast the task context into the work language and write every work-language surface from that recast — do not transliterate the chat. Unset → `en` (today's behavior).

## Work order: Doc → Test → Code
1. **Doc** — Write the behavior/contract to be changed into the SSOT (MISSION, README, CLAUDE.md, ARCHITECTURE, ADR) first.
2. **Test** — Translate the doc into a failing test. Confirm the intended failure.
3. **Code** — Minimum implementation to pass the test.

Each phase should be its own commit when possible. The commit graph of the PR should show Doc → Test → Code.

Relaxed when: `fix` (reproduce-first), `refactor` (doc skippable if external behavior unchanged), `perf` (measure first), spikes, one-line typos. State the reason in one line in the PR body Plan.

Strict: `feat`, `docs`, external contract / API / schema changes.

## Recall routing
Reach for `/recall` at **recall-shaped** moments — user-asked ("have we…?", "what did we decide about…?") or self-identified before planning/a decision. Pointers-only; targeted read only if relevant. Full contract: SPEC §5.25.

## Active SSOT maintenance
Code changes commit with the SSOT items they invalidate or update. If a doc change is intentionally omitted, the commit body says `Docs: n/a — <short reason>`.

`docs/*.md` are **thin pointers**, not parallel content — each leads with a "Full details in SPEC §X" reference and carries no detailed contract content that could drift from SPEC (SPEC §9; smoke-enforced). SPEC is the single source; a digest that restates a contract is a second copy to hand-sync.

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
| Code-phase implementation (Phase C), default route | `implementer` (#477) |
| Pre-commit / pre-PR review | `code-reviewer` |
| Auth/input/deps/crypto changes | `security-reviewer` |
| Rationale check on a proposed issue body | `issue-reviewer` |
| Approach / alternatives check on a planner output | `plan-reviewer` |
| Quality check on a proposed Directive or completion claim | `activation-reviewer` (dir-mode, §4.9) |

In `unattended` mode, the reviewers above substitute for human review at their respective checkpoints (SPEC §1.5 operating-mode coupling).

**Session-restart caveat** (SPEC §4.9.3): Claude Code enumerates `subagent_type` values from `.claude/agents/*.md` at session start. A reviewer added mid-session falls back to `general-purpose` routing until the next session restart — file presence is necessary but not sufficient. The fallback is functionally complete (the agent's prompt instructs `general-purpose` to behave as the new reviewer); restart is canonical.

Don't re-run an exploration in `explorer` that the main assistant already did.

**Working-tree isolation** (SPEC §1.5, #285): the read-only-by-intent subagents (`code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `activation-reviewer`, `explorer`) share the parent's working tree and carry `Bash`, so a tree-mutating git command inside one can silently revert/stage the parent's uncommitted work. Invoke them with **worktree isolation** (canonical); their prompts also constrain them to read-only git. Run `git status` before each commit/merge as the catch-all. The **write-capable `implementer`** is deliberately **not** isolated (its Code commit must land on the PR branch) — it substitutes a **path-scoped-add discipline** (stage only manifest-named paths; never `git add -A`/`-u`) for isolation, and the caller surfaces a dirty tree before dispatch (SPEC §4.12, §5.28).

## Branch & commit convention
- Branch: `<gh-username>/<type>/[<issue#>-]<slug>`
- Commit: `<type>(#<issue>)[!]: <subject>` (codepoint 1–72)
- Required group (`feat`/`fix`/`docs`/`refactor`/`perf`) — issue # required
- Optional group (`test`/`style`/`build`/`ci`/`chore`/`revert`) — issue # optional
- `Closes #N` (single/final PR), `Refs #N` (intermediate PR)
- Recommended: assemble the commit via `eng_commit <type> <issue> "<subject>" [body…]` (`helpers/eng_commit.sh`, SPEC §10.2) — validates the subject before committing + array-argv build avoids multibyte/multiline `-m` pitfalls. Offered, not forced; the commit-format hook stays the net.

## What hooks enforce
Pointer index — every contract below lives in full in SPEC §6.1 (PreToolUse matcher table + `safe_source` fail-policy table), with the binding/state/banner items in §3.2.1, §3.2.2, and §6.5(c). Enforcement-style face (negative block vs positive guide) is chosen by cost-asymmetry — SPEC §6.0.

- **protected-branch** — direct commit/push to `main`/`master`/`release/*` blocked; the **Stage-0 exception** lets `/bootstrap-repo` seed an unborn HEAD (SPEC §6.1, §5.0).
- **force-push** — force-push allowed only to an explicitly-named non-protected branch; protected-named or bare/remote-only blocked; `--amend` after push and `--no-verify` blocked (SPEC §6.1).
- **secret** — secret patterns in the staged diff blocked, with a `.shellsecretignore` path allow-list (SPEC §6.1).
- **ac-closeout** — `gh pr merge` blocked when a linked issue has unchecked AC items and no `## AC closeout` marker comment yet (SPEC §6.1).
- **merge-strategy** — `gh pr merge` to the default branch blocked unless the strategy is `--merge` (SPEC §6.1, §5.7.1).
- **sensitive-file** — Edit/Write on `.env`, `*.pem`, `credentials*`, `id_rsa*`, `id_ed25519*` blocked, including under both carve-outs (SPEC §6.1).
- **out-of-scope (Edit/Write)** — Edit/Write outside the registry blocked, except the two carve-outs `$CLAUDE_ENG_SHELL_ROOT/` and `$HOME/.claude/` (SPEC §6.1).
- **out-of-scope (destructive)** — `rm`/`mv`/`cp` with a force/recursive flag in any surface form and out-of-registry args blocked; no carve-out (SPEC §6.1).
- **shell-root resolution** — hooks resolve the shell via `$CLAUDE_ENG_SHELL_ROOT` else self-locate through the per-project `.claude/eng-shell-root` binding symlink, so a plain `claude` in a target needs no global env (SPEC §3.2.1).
- **per-project state** — audit log, caches, and the scope-guard registry resolve per-project under `eng-state/` (`eng_state_dir`/`eng_registry_file`); missing/empty registry fails open (SPEC §3.2.2).
- **SessionStart banner** — surfaces the detectable silent-no-op states (runtime `hookrt.sh` missing; and a present-but-empty scope registry that silently disarms enforcement, #502) via a once-per-session banner naming the fix (SPEC §6.5(c)).
- **safe_source** — every helper source (hook-to-helper and helper-to-helper) goes through `safe_source`, fail-open with `audit_log warn <category> helper-missing` on miss (SPEC §6.1 fail-policy table).
- **pass-through invariant** — every matcher reaches a decided state per fire; happy paths `mark_allow` silently, anomalous silent fall-through is caught by `pass_through_trace` (SPEC §6.1).
- **audit observability** — records carry an additive `source` field (`test` only via the harness-owned, uninjectable marker) and reviewers emit a categorized reject record; both observability surfaces, not gates (SPEC §6.1).
- **type-aware hooks** — `issue_type.sh` predicates drive the AC-closeout Directive skip and the `proposed-protect` matcher (block branching a `status:proposed` or Directive Issue) (SPEC §1.7, §6.1).
- **trusted-filer-mutate** — blocks a trusted-filer `gh issue close` without `--reason completed`, and `--remove-label directive` on any filer (SPEC §6.1).
- **label-parent-consistency** — blocks a `gh issue edit --add-label {execution|task|bug}` that contradicts the body's line-1 parent marker (plus the initiative/directive + parent-XOR arms) (SPEC §6.1).
- **initiative-readonly** — blocks mutating `gh issue edit`/`close`/`reopen` on an `initiative` Issue (comments always allowed) (SPEC §6.1).
- **directive-close** — blocks a GitHub close keyword + Directive `#N` in a PR body (inline `--body`) or commit message; the auto-close would bypass `/complete-directive` (§5.13). Execution Issues unaffected; per-`#N` fail-open (SPEC §6.1).

Escape — three audit-logged forms. The **primary in-agent** form is a **file-based skip token** (`scripts/eng_skip.sh <cat> <cmd_fingerprint> [reason]`, one-shot + 60s TTL, read by the hook at fire time so the harness can't strip it). The two in-command forms — a trailing `# claude-eng:skip=<cat> reason=<why>` sentinel and a leading `SKIP_HOOKS=<cat> SKIP_REASON='<why>'` env-prefix — are **verbatim-delivery only** (a real shell, the smoke harness); the live Claude Code Bash tool strips both before the hook, so neither lands in-harness. Real terminal / non-protected-branch + rename is the fallback. Full contract: SPEC §7.

## Boundary
- The shell never touches user-global state (`~/.zshrc`, `~/.claude`, global git config, etc.).
- The shell only operates within paths registered in the registry.
