# GHJig-Claude

**English** | [한국어](README.ko.md)

**An opinionated workflow shell for [Claude Code](https://docs.claude.com/claude-code).** It wraps a Claude Code session in the engineering discipline a senior human would apply on a GitHub repo — issue → branch → draft PR → reviewed commits → ready merge — rendered as hooks, slash commands, subagents, and an audit trail. The point: let an AI drive end-to-end engineering work without drifting past the checks a careful human would not skip. In **`unattended`** mode it goes further — file → branch → Doc/Test/Code → review → merge with no human in the loop: reviewer subagents stand in for human approval at each gate, and a hard blocker parks with an audit trail instead of merging blind.

- **[MISSION.md](MISSION.md)** — what success looks like twelve months out, who this is for, and what is explicitly *not* a goal.
- **[SPEC.md](SPEC.md)** — the single self-contained specification (~2,000 lines). Start from its **Table of contents**; read individual sections with `Read --offset --limit` rather than loading the whole file.

## Install

```bash
git clone <this-repo-url> GHJig-Claude
cd GHJig-Claude
./scripts/bootstrap.sh                 # checks dependencies only — never edits ~/.zshrc
export PATH="$PWD/bin:$PATH"            # optional — only to run `ghjig` from any dir (or: alias ghjig="$PWD/bin/ghjig")
```

`bootstrap.sh` only verifies dependencies — `git`, `gh`, `jq` are required; `python3` is recommended (several helpers fall back to less-precise behavior without it). It never modifies `~/.zshrc` or any other user-global file.

## Quick start

```bash
# Prerequisites: gh auth login (a token that can open PRs + manage issues).
# What this puts in your repo, and the ghjig-vs-claude choice, are under
# "Adopting it on your repo" below — read it before the first real run.

# One command — local path or repo URL. setup.sh runs deps check →
# registers-or-clones → onboard pre-flight → offers dir-mode (default N) →
# prints the next command to run:
./scripts/setup.sh ~/code/<repo>                              # existing local repo (the common path)
#   …or:  ./scripts/setup.sh https://github.com/<owner>/<repo>.git   # clone a fresh target into workspace/
#   add --enter to exec `claude` directly instead of printing the next command.
# Under the hood it folds together what used to be separate steps:
#   register.sh / clone-into.sh + (optional) PATH export + claude.

# Inside the session — the engineering loop:
> /onboard                      # one-time, read-only: upstream, permissions, SSOT, CI
> /file-issue <description>     # files the Issue as status:proposed
> /activate <issue#>            # Proposed → Active (reviewer-gated; required before /work-on)
> /work-on <issue#>             # branch + draft PR + planner
                                #   …or  /work-on <issue#> --base experiment/foo  (topic-branch flow, SPEC §10.5)
> /ship                         # review, tick AC, mark ready (→ merge in unattended mode)
```

## Adopting it on your repo

Before the loop above runs cleanly on a real project, four things are worth knowing.

**Prerequisites.** Beyond the `bootstrap.sh` deps (`git` / `gh` / `jq`, `python3` recommended), the GitHub flow needs `gh auth login` with a token that can open PRs and manage issues. Adopting **dir-mode** additionally needs the `project` token scope (the dir-mode GitHub Project is created by `setup_project.sh`) and permission to push workflows (issue/Project mirroring installs `.github/workflows/`). `/onboard` reports what's missing — fix auth before filing the first issue.

**Footprint — what lands in your repo, and what's tracked.** Injection (`clone-into.sh` / `register.sh`) creates **symlinks** under the target's `.claude/`: `ghjig-root` (→ the canonical shell), `settings.local.json` (→ the shell's injected hooks), and one per `agents/` + `commands/*.md` asset — plus a per-project registry/state dir under `ghjig-state/`. The shell adds `ghjig-root`, `settings.local.json`, and `ghjig-state/` to the target's `.git/info/exclude`, so they never appear in your `git status`; the `agents`/`commands` symlinks point into the shell and are not committed either. A pre-existing **real** file of the same name is *skipped with a warning*, never overwritten — the shell will not clobber an existing `.claude/`.

**Invocation — `ghjig` or plain `claude`.** The `ghjig` PATH wrapper (from Install) works from anywhere. Inside a registered target you can also just run `claude`: the hooks self-locate the shell through the `.claude/ghjig-root` binding symlink, so no global `GHJIG_SHELL_ROOT` env is needed (SPEC §3.2.1).

**`/onboard` (one-time, read-only).** Run it right after registering. It reports six checks — upstream/fork, push permission, SSOT files, `.github/`, branch protection, CI — each ✓/✗, makes **no automatic changes**, and ends with recommended next actions. A ✗ (e.g. the repo is a fork, or you lack push permission — the shell is upstream-only) is your cue to fix the environment before `/file-issue`.

> **dir-mode mutates the target.** Unlike everything above, `/onboard-dir-mode` is not a free toggle: it opens a **PR into your repo** adding issue templates, mirroring workflows, and a changelog substrate, and it creates labels + a GitHub Project. Adopt it deliberately — full flow in [docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md).

## How the loop runs

Two operating layers, both following the same **generate → review → gated approval → audit** pattern:

- **eng-mode** — engineering execution. `/file-issue` → `/activate` → `/work-on` (branch + draft PR) → Doc → Test → Code commits → `/ship` (runs reviewers, ticks AC, marks ready) → merge.
- **dir-mode** — setting direction. A Directive scopes several Execution Issues under one coherent "why" — a feature with subsystems, a refactor, a migration alike — without being directly executable itself. `/file-directive` → `/activate` → `/file-issue --parent <N>` to spin out Execution Issues → `/complete-directive` once the Directive's success signals are met. An optional **Initiative** tier sits above Directives — a planning artifact the shell *consumes, not authors* (`/consume-initiative`, `/initiative-feedback`). The full flow and substrate install (`/onboard-dir-mode`) are in **[docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md)**; topic-branch isolation for multi-PR Directives is SPEC §10.5.

### Attended vs unattended

Both run the *same* gated loop; they differ only in **who signs off**.

- **`attended`** (default) — the agent stops at **PR-ready** and hands a clean, reviewed draft to a human for the final read + merge. The autonomy ceiling is PR-ready.
- **`unattended`** — the five reviewer subagents (`code-`, `security-`, `issue-`, `plan-`, `activation-`) **substitute for the human approvals** at their checkpoints, and `/ship` carries past PR-ready to the terminal step: **merge a clean PR, or park a hard blocker** (incompatible plan, secret detected, AC unticked) as an audit-logged `parked` state. The intended use is the overnight one — **point it at well-scoped issues and wake up to quality-controlled merged PRs or audit-logged parks, not silent half-finished work.**

This is review *substituted*, not *skipped*: every verdict is a reviewer artifact a human can override, every block is escapable and audit-logged, and the directing layer never autonomously decides direction (SPEC §1.7). Set per-target with `echo unattended > .claude/state/mode`, or override per-run with `/ship --mode=unattended`. Full resolution priority + blocker rules: SPEC §5.7.1.

## Why this shape

One **design hypothesis** drives the design — a working prior the shell is built around, not a measured law it asserts: **an AI agent's output quality tends to track the size and relevance of its working context.** Free-form sessions read opportunistically, accumulate digressions, and ask the model to hold the whole task in one window — and as that window fills with irrelevant material, they drift, hallucinate invariants, and lose preconditions. So the shell splits each task into narrow, well-scoped phases and pushes everything else *out* of the active context. Engineering discipline is the lever; context discipline is the effect. The *generic* form of this — keeping one session's context small — is increasingly native to the Claude Code harness; the shell treats the harness as a **rising floor** and concentrates on the harness-orthogonal forms (task-boundary handoff, GitHub-artifact memory, engineering enforcement), classified mechanism-by-mechanism in [SPEC §1.9](SPEC.md):

- **Doc → Test → Code** splits the job into three short-context steps — each phase reads only what it needs, and each phase's output (a doc commit, a failing-test commit, a passing-test commit) is the next phase's input.
- **Subagents run in isolated windows.** `planner`, `doc-writer`, `test-writer`, and the `*-reviewer` family spawn fresh, do their job, and return a verdict — not a transcript. Exploration and planning burn never pollute the main session.
- **GitHub artifacts are the durable memory.** Branch state, PR body, AC checkboxes, commit history, and the audit log survive across sessions; a resumed session reads its position from the repo, and SessionStart re-injects only the relevant slice.
- **Hooks enforce the rules** so the agent doesn't spend context policing itself — protected-branch commits, secrets, malformed messages, and AC-unticked merges are refused, with an audit-logged escape hatch for the cases that warrant one.
- **Reviewers judge from the artifact, not the conversation** — diff + PR body + MISSION, never the discussion that produced them. A fresh reader catches what a primed one cannot.

Every mechanism aims at the same lever: keep the slice of context the model reasons over as small and relevant as possible. That is why the shell is built around an artifact hierarchy (`MISSION.md` → Directive → Execution Issue → PR → commits) rather than a long-running conversation — each level is a context boundary with its own reviewer, and each level's output is what the next level reads.

## Subagents

Ten: `explorer`, `planner`, `plan-challenger`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `activation-reviewer`. The five reviewers (`code-`, `security-`, `issue-`, `plan-`, `activation-`) substitute for human-confirm checkpoints in `unattended` mode; `plan-challenger` (×2, distinct axes) adversarially challenges the planner's base plan for `plan-reviewer` to judge. See [docs/SUBAGENTS.md](docs/SUBAGENTS.md) for when to use each.

## What the hooks enforce

The environment refuses what a careful engineer would not do and audit-logs every block to `.claude/audit/audit.jsonl`. The surface includes:

- **Git safety** — direct commit/push to a protected branch, force-push, `--amend` after push, `--no-verify`.
- **Secrets & sensitive files** — secret patterns in the staged diff (path allow-list via `.shellsecretignore`); edits to `.env`, `*.pem`, `credentials*`.
- **Scope** — Edit/Write, or destructive `rm -rf`/`mv -f`/`cp -f`, against paths outside the registered scope.
- **Workflow integrity** — `gh pr merge` with unchecked AC (`ac-closeout`) or a non-`--merge` strategy into the default branch (`merge-strategy`); branch creation against a `status:proposed` or Directive Issue (`proposed-protect`); a label that contradicts an Issue's parent-marker (`label-parent-consistency`); and trusted-filer Issue mutations.

Every block is escapable and audit-logged. In the Claude Code Bash tool use the trailing sentinel `<command>  # ghjig:skip=<category> reason=<why>`; the leading `SKIP_HOOKS=<category> SKIP_REASON='<why>' <command>` env-prefix form works only where it reaches the command string (a real shell, the smoke harness). The full enforcement surface, fail-policy, and tuning mechanisms are in **SPEC §6.1 / §6.5 / §7**.

## Configuration toggles

All optional; per-target state lives under `.claude/state/` (gitignored), env vars take priority. The full toggle catalog — operating mode, Co-Authored-By trailer, cache TTLs, timeouts, the unattended park log, the dir-mode Project name, and more — is in **[docs/CONFIG.md](docs/CONFIG.md)**.

## Versioning

The shell version is a single [semver](https://semver.org) 0.x line in the top-level `VERSION` file (`MAJOR=0` throughout v0); tags are `v` + semver (e.g. `v0.2.0`). `ghjig --version` prints it — short-circuited before registry/scope resolution, so it works from any cwd. Per [SemVer 2.0 §4](https://semver.org/#spec-item-4), 0.x bumps are informational signals, not contracts; tags are pushed manually by the maintainer after a milestone merges. Per-PR changelog fragments go under `changelog_unreleased/<category>/<N>.md` ([TEMPLATE](changelog_unreleased/TEMPLATE.md)), and `/release <X.Y.Z>` consolidates them into [CHANGELOG.md](CHANGELOG.md). Full contract: SPEC §18.

## Docs

- [MISSION.md](MISSION.md) — long-term direction and success criteria.
- [SPEC.md](SPEC.md) — the single self-contained specification (SSOT); start from the TOC.
- [docs/ENGINEERING_FLOW.md](docs/ENGINEERING_FLOW.md) — step-by-step engineering flow.
- [docs/DIR_MODE_FLOW.md](docs/DIR_MODE_FLOW.md) — dir-mode flow (Directives, Initiatives, substrate tiers).
- [docs/SUBAGENTS.md](docs/SUBAGENTS.md) — subagent usage guide.
- [docs/HARNESS_OVERLAP.md](docs/HARNESS_OVERLAP.md) — harness-overlap classification (cede / policy / safety-redundancy).
- [docs/CONFIG.md](docs/CONFIG.md) — configuration toggles.
- [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md) — bypassing hooks safely.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common blocks and fixes.

## Verify

```bash
./scripts/test/smoke.sh           # 733+ assertions across hooks, helpers, slash commands
./scripts/build_toc.sh --check    # SPEC.md TOC freshness
```
