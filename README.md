# claude-eng-shell

**English** | [한국어](README.ko.md)

**An opinionated workflow shell for [Claude Code](https://docs.claude.com/claude-code).** It wraps a Claude Code session in the engineering discipline a senior human would apply on a GitHub repo — issue → branch → draft PR → reviewed commits → ready merge — rendered as hooks, slash commands, subagents, and an audit trail. The point: let an AI drive end-to-end engineering work without drifting past the checks a careful human would not skip.

- **[MISSION.md](MISSION.md)** — what success looks like twelve months out, who this is for, and what is explicitly *not* a goal.
- **[SPEC.md](SPEC.md)** — the single self-contained specification (~2,000 lines). Start from its **Table of contents**; read individual sections with `Read --offset --limit` rather than loading the whole file.

## Install

```bash
git clone <this-repo-url> claude-eng-shell
cd claude-eng-shell
./scripts/bootstrap.sh                 # checks dependencies only — never edits ~/.zshrc
export PATH="$PWD/bin:$PATH"            # or: alias claude-eng="$PWD/bin/claude-eng"
```

`bootstrap.sh` only verifies dependencies — `git`, `gh`, `jq` are required; `python3` is recommended (several helpers fall back to less-precise behavior without it). It never modifies `~/.zshrc` or any other user-global file.

## Quick start

```bash
# Clone a target repo into the shell's workspace/ (or register an external path — see below).
./scripts/clone-into.sh https://github.com/<owner>/<repo>.git
cd workspace/<repo>
claude-eng

# Inside the session — the engineering loop:
> /onboard                      # one-time: check upstream, permissions, SSOT, CI
> /file-issue <description>     # files the Issue as status:proposed
> /activate <issue#>            # Proposed → Active (reviewer-gated; required before /work-on)
> /work-on <issue#>             # branch + draft PR + planner
                                #   …or  /work-on <issue#> --base experiment/foo  (topic-branch flow, SPEC §10.5)
> /ship                         # review, tick AC, mark ready (→ merge in unattended mode)
```

Register an external repo instead of cloning into `workspace/`:

```bash
./scripts/register.sh ~/code/<repo>     # or: claude-eng ~/code/<repo> — an unregistered path prompts to register
```

## How the loop runs

Two operating layers, both following the same **generate → review → gated approval → audit** pattern:

- **eng-mode** — engineering execution. `/file-issue` → `/activate` → `/work-on` (branch + draft PR) → Doc → Test → Code commits → `/ship` (runs reviewers, ticks AC, marks ready) → merge.
- **dir-mode** — setting direction. A Directive scopes several Execution Issues under one coherent "why" — a feature with subsystems, a refactor, a migration alike — without being directly executable itself. `/file-directive` → `/activate` → `/file-issue --parent <N>` to spin out Execution Issues → `/complete-directive` once the Directive's success signals are met. An optional **Initiative** tier sits above Directives — a planning artifact the shell *consumes, not authors* (`/consume-initiative`, `/initiative-feedback`). The full flow and substrate install (`/onboard-dir-mode`) are in **[docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md)**; topic-branch isolation for multi-PR Directives is SPEC §10.5.

In **`attended`** mode (default) the agent stops at PR-ready and waits for a human to review + merge. In **`unattended`** mode the reviewer subagents substitute for the human approvals, and `/ship` continues to merge (clean PR) or park (hard blocker). Set per-target with `echo unattended > .claude/state/mode`, or override per-run with `/ship --mode=unattended`. Full resolution priority + blocker rules: SPEC §5.7.1.

## Why this shape

One load-bearing observation drives the design: **an AI agent's output quality is bounded by the size and relevance of its working context.** Free-form sessions read opportunistically, accumulate digressions, and ask the model to hold the whole task in one window — and as that window fills with irrelevant material, they drift, hallucinate invariants, and lose preconditions. So the shell splits each task into narrow, well-scoped phases and pushes everything else *out* of the active context. Engineering discipline is the lever; context discipline is the effect:

- **Doc → Test → Code** splits the job into three short-context steps — each phase reads only what it needs, and each phase's output (a doc commit, a failing-test commit, a passing-test commit) is the next phase's input.
- **Subagents run in isolated windows.** `planner`, `doc-writer`, `test-writer`, and the `*-reviewer` family spawn fresh, do their job, and return a verdict — not a transcript. Exploration and planning burn never pollute the main session.
- **GitHub artifacts are the durable memory.** Branch state, PR body, AC checkboxes, commit history, and the audit log survive across sessions; a resumed session reads its position from the repo, and SessionStart re-injects only the relevant slice.
- **Hooks enforce the rules** so the agent doesn't spend context policing itself — protected-branch commits, secrets, malformed messages, and AC-unticked merges are refused, with an audit-logged escape hatch for the cases that warrant one.
- **Reviewers judge from the artifact, not the conversation** — diff + PR body + MISSION, never the discussion that produced them. A fresh reader catches what a primed one cannot.

Every mechanism aims at the same lever: keep the slice of context the model reasons over as small and relevant as possible. That is why the shell is built around an artifact hierarchy (`MISSION.md` → Directive → Execution Issue → PR → commits) rather than a long-running conversation — each level is a context boundary with its own reviewer, and each level's output is what the next level reads.

## Subagents

Nine: `explorer`, `planner`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `activation-reviewer`. The five reviewers (`code-`, `security-`, `issue-`, `plan-`, `activation-`) substitute for human-confirm checkpoints in `unattended` mode. See [docs/SUBAGENTS.md](docs/SUBAGENTS.md) for when to use each.

## What the hooks enforce

The environment refuses what a careful engineer would not do and audit-logs every block to `.claude/audit/audit.jsonl`. The surface includes:

- **Git safety** — direct commit/push to a protected branch, force-push, `--amend` after push, `--no-verify`.
- **Secrets & sensitive files** — secret patterns in the staged diff (path allow-list via `.shellsecretignore`); edits to `.env`, `*.pem`, `credentials*`.
- **Scope** — Edit/Write, or destructive `rm -rf`/`mv -f`/`cp -f`, against paths outside the registered scope.
- **Workflow integrity** — `gh pr merge` with unchecked AC (`ac-closeout`) or a non-`--merge` strategy into the default branch (`merge-strategy`); branch creation against a `status:proposed` or Directive Issue (`proposed-protect`); a label that contradicts an Issue's parent-marker (`label-parent-consistency`); and trusted-filer Issue mutations.

Every block is escapable and audit-logged. In the Claude Code Bash tool use the trailing sentinel `<command>  # claude-eng:skip=<category> reason=<why>`; the leading `SKIP_HOOKS=<category> SKIP_REASON='<why>' <command>` env-prefix form works only where it reaches the command string (a real shell, the smoke harness). The full enforcement surface, fail-policy, and tuning mechanisms are in **SPEC §6.1 / §6.5 / §7**.

## Configuration toggles

All optional; per-target state lives under `.claude/state/` (gitignored), env vars take priority. The full toggle catalog — operating mode, Co-Authored-By trailer, cache TTLs, timeouts, the unattended park log, the dir-mode Project name, and more — is in **[docs/CONFIG.md](docs/CONFIG.md)**.

## Versioning

The shell version is a single [semver](https://semver.org) 0.x line in the top-level `VERSION` file (`MAJOR=0` throughout v0); tags are `v` + semver (e.g. `v0.2.0`). `claude-eng --version` prints it — short-circuited before registry/scope resolution, so it works from any cwd. Per [SemVer 2.0 §4](https://semver.org/#spec-item-4), 0.x bumps are informational signals, not contracts; tags are pushed manually by the maintainer after a milestone merges. Per-PR changelog fragments go under `changelog_unreleased/<category>/<N>.md` ([TEMPLATE](changelog_unreleased/TEMPLATE.md)), and `/release <X.Y.Z>` consolidates them into [CHANGELOG.md](CHANGELOG.md). Full contract: SPEC §18.

## Docs

- [MISSION.md](MISSION.md) — long-term direction and success criteria.
- [SPEC.md](SPEC.md) — the single self-contained specification (SSOT); start from the TOC.
- [docs/ENGINEERING_FLOW.md](docs/ENGINEERING_FLOW.md) — step-by-step engineering flow.
- [docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md) — dir-mode flow (Directives, Initiatives, substrate tiers).
- [docs/SUBAGENTS.md](docs/SUBAGENTS.md) — subagent usage guide.
- [docs/CONFIG.md](docs/CONFIG.md) — configuration toggles.
- [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md) — bypassing hooks safely.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common blocks and fixes.

## Verify

```bash
./scripts/test/smoke.sh           # 547 assertions across hooks, helpers, slash commands
./scripts/build_toc.sh --check    # SPEC.md TOC freshness
```
