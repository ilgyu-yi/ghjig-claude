# claude-eng-shell

**An opinionated workflow shell for [Claude Code](https://docs.claude.com/claude-code).** It wraps a Claude Code session in the engineering discipline a senior human would apply on a GitHub repository — issue → branch → draft PR → reviewed commits → ready merge — and renders that discipline as hooks, slash commands, subagents, and an audit trail. The point is to let an AI drive end-to-end engineering work without drifting past the checks a careful human would not skip.

- **[MISSION.md](MISSION.md)** — what success looks like twelve months out, who this is for, and what is explicitly not a goal.
- **[SPEC.md](SPEC.md)** — the single self-contained specification (~1,300 lines). Start from the **Table of contents** at the top and read individual sections with `Read --offset --limit` rather than loading the whole file.

## Why this shape

A small but load-bearing observation drives the design: **an AI agent's output quality is bounded by the size and relevance of its working context.** A free-form session reads files opportunistically, accumulates conversational digressions, and asks the model to hold the whole task in one window. As that window fills with material that isn't relevant to the next decision, performance degrades — drift, hallucinated invariants, half-finished implementations, lost preconditions.

So the shell does not try to give the agent better instructions for "do the whole task." It instead splits one task into a sequence of **narrow, well-scoped phases**, and pushes everything that doesn't belong in the current phase *out* of the active context. Engineering discipline is the lever; context discipline is the effect:

- **Doc → Test → Code splits the job into three short-context steps.** The doc phase reads the SSOT (MISSION, SPEC, CLAUDE.md). The test phase reads the contract just written + the test rig. The code phase reads the failing test + the relevant implementation. None of the three has to hold the others in working memory, and each phase's output (a doc commit, a failing-test commit, a passing-test commit) is the input the next phase needs — nothing more.
- **Subagents run in isolated context windows.** `planner`, `doc-writer`, `test-writer`, and the `*-reviewer` family each spawn with a fresh context, do their job, and return a summary. Exploration burn, planning detours, and review reasoning never pollute the main session. The main agent reads a verdict, not a transcript.
- **GitHub artifacts are the durable memory.** Branch state, draft-PR body, AC checkboxes, merged commit history, audit log — these survive across sessions. A resumed session reads its position from the repo, not from a long conversation transcript that may not exist anymore. SessionStart re-injects only the slice relevant to where the work currently sits.
- **Hooks enforce the rules so the agent doesn't have to remember them.** Protected-branch commits, secrets in the diff, malformed commit messages, AC-unticked merges — the environment refuses, with an audit-logged escape hatch for the cases that warrant one. The agent's context stays focused on the work, not on policing itself against every rule in the SPEC.
- **Reviewers judge from the artifact, not the conversation.** `code-reviewer`, `security-reviewer`, `directive-reviewer`, and their peers see the diff + PR body + MISSION — not the discussion that produced them. Arguments that sounded convincing fifty messages ago carry no weight at the gate. This isolation is the point: a fresh reader catches what a primed one cannot.

Put together: the shell's mechanisms are not independent good-engineering practices stacked on each other. They are all aimed at the same lever — keeping the slice of context the model is reasoning over at any given moment as small and relevant as possible.

This is why the shell is structured around a hierarchy of artifacts (`MISSION.md` → Directive Issue → Execution Issue → PR → commits) rather than a long-running conversation. Each level is a context boundary. Each level has its own reviewer. Each level's output is what the next level reads.

## How the loop runs

Two operating layers, both following the same generate → review → gated approval → audit pattern:

- **eng-mode** — engineering execution. `/file-issue` → `/work-on <N>` (creates branch + draft PR) → Doc → Test → Code commits → `/ship` (runs reviewers, ticks AC, marks ready) → merge.
- **dir-mode** — directing maintenance. `/file-directive` → `/activate-directive` → `/file-issue --parent <N>` to spin out Execution Issues → `/complete-directive` when success signals are met. Manual mode switching in v0; the orchestrator that auto-switches is v1+ (SPEC §0.4).

In `unattended` mode the reviewer subagents substitute for the human approvals at each checkpoint; in `attended` mode (default) the agent stops at PR-ready and waits for a human review.

## Install

```bash
git clone <this-repo-url> claude-eng-shell
cd claude-eng-shell
./scripts/bootstrap.sh
```

`bootstrap.sh` only checks dependencies — `git`, `gh`, `jq` are required; `python3` is recommended (used by several helpers; missing python falls back to less-precise behavior). It never modifies `~/.zshrc` or any other user-global file. Add the binary to `PATH` or alias it yourself:

```bash
export PATH="$PWD/bin:$PATH"
# or
alias claude-eng="$PWD/bin/claude-eng"
```

## Quick start

```bash
# Clone a target repo into the shell's workspace/.
./scripts/clone-into.sh https://github.com/<owner>/<repo>.git
cd workspace/<repo>
claude-eng

# Inside the session:
> /onboard
> /file-issue <description>
> /work-on <issue#>                          # default: branches from main
> /work-on <issue#> --base experiment/foo    # topic-branch flow (SPEC §10.5)
> /ship
```

External paths register too:

```bash
./scripts/register.sh ~/code/<repo>
# or: claude-eng ~/code/<repo>   ← unregistered path prompts to register
```

### Dir-mode: Directive-scoped work

A **Directive** is a medium-term directional context that scopes one or more Execution Issues (SPEC §1.7, §2.1). Use one when the work crosses 2-3 PRs or needs a coherent "why are we doing this" anchor — a refactor, a migration, a feature with subsystems. For one-off changes, regular `/file-issue` is enough.

**Single-Directive flow (most common):**

```bash
# Inside the session:
> /file-directive               # author Directive; status:proposed, reviewer-gated
> /activate-directive <N>       # Proposed → Active (removes status:proposed)
> /file-issue --parent <N> <description>   # spawn Execution Issue parented under Directive #N
> /work-on <execution-#>        # eng-mode from here on
> /ship
# ... repeat /file-issue --parent / /work-on / /ship per Execution Issue ...
> /complete-directive <N>       # reviewer evaluates closed-Execution-Issue evidence
```

**Multi-PR Directive with topic-branch isolation (SPEC §10.5):**

When the work spans several PRs and you want isolation from `main` until consolidation:

```bash
# Create the topic branch from main (the shell does NOT auto-create it):
$ git checkout main && git pull
$ git checkout -b feature/directive-<N> && git push -u origin feature/directive-<N>

# Inside the session, for each Execution Issue under the Directive:
> /file-issue --parent <N> <description>
> /work-on <execution-#> --base feature/directive-<N>   # sub-task PR; uses Refs #<execution-#>
> /ship

# When all Execution Issues are done, consolidate to main:
$ gh pr create --base main --head feature/directive-<N> --title "..." --body "$(cat <<'EOF'
Closes #<exec-1>
Closes #<exec-2>
...
EOF
)"

# Then close the Directive:
> /complete-directive <N>
```

The Directive Issue itself is never branched — the `directive-protect` hook blocks `git checkout -b` against a Directive Issue. The Directive scopes the work; the Execution Issues do the work.

### Dir-mode substrate (Project v2)

For **dir-mode** (SPEC §1.7), bootstrap the GitHub Project v2 substrate from inside a registered target repo:

```bash
./scripts/setup_project.sh   # idempotent — creates "<repo-name> roadmap" with
                             # 6 fields and links to the repo. On re-run,
                             # reconciles SINGLE_SELECT options additively
                             # (preserves user-added options). The Iteration
                             # field is user-added via the GH UI (gh CLI lacks
                             # the ITERATION data-type). Schema locked
                             # inline in scripts/setup_project.sh.
```

## Operating modes

| Mode | `/ship` terminal behavior | Use |
|---|---|---|
| `attended` (default) | stops at PR-ready | human reviews + merges |
| `unattended` | continues to merge (clean) or park (hard blocker) | overnight runs, batched fixes |

Set per-target with `echo unattended > .claude/state/mode`. Override per-invocation with `/ship --mode=unattended`. See SPEC §5.7.1 for the full resolution priority and blocker classification.

## What the hooks actually enforce

- Protected-branch direct commit/push, force push, `--amend` after push, `--no-verify`
- Secret patterns in the staged diff (emits `file:line: <id>` markers; path allow-list via `.shellsecretignore` at the target-repo root)
- Edits to `.env`, `*.pem`, `credentials*`
- Edit/Write outside the registered scope, and `rm -rf`/`mv -f`/`cp -f` against out-of-registry paths
- `gh pr merge` when a linked issue has unchecked AC and no `## AC closeout` marker comment (`/ship` step 7.6 invokes `scripts/ac_closeout.sh` to satisfy by construction)
- Branch creation against a Directive Issue (Directives are not directly executable — must be turned into Execution Issues first via `/file-issue --parent`)
- `gh issue close` without `--reason completed` on a trusted-filer Issue; `--remove-label directive` from any filer

Every block is escapable via `SKIP_HOOKS=<category> SKIP_REASON='<why>' <command>` and audit-logged at `.claude/audit/audit.jsonl`. SessionStart surfaces silent-no-op states (workspace injected but launched via plain `claude` instead of `claude-eng`, or `hookrt.sh` missing) — otherwise the hooks would evaporate without warning. See SPEC §6.1 / §6.5 / §7 for the full enforcement surface and the structural tuning mechanisms for repeated false positives.

## Subagents

Ten in total: `explorer`, `planner`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `directive-reviewer`, `triage-reviewer`. The six reviewers (`code-`, `security-`, `issue-`, `plan-`, `directive-`, `triage-`) substitute for human-confirm checkpoints in `unattended` mode. See [docs/SUBAGENTS.md](docs/SUBAGENTS.md) for when to use each.

## More commands

The full command surface is documented in SPEC §5; the most-used ones beyond `/file-issue` / `/work-on` / `/ship` / dir-mode:

- `/discuss <observation>` — friction-free filing for "weird but not a bug" observations (SPEC §5.19). Bypasses the rationale-triad gate; close as promoted (concrete Issue filed) or no-action.
- `/audit [<filter>]` — query the audit log for recent blocks, escapes, warns. Filter is a substring match against the log (e.g., `/audit force-push`, `/audit escape`). Use when debugging a hook that fired unexpectedly.
- `/status` — one-shot summary of current branch / issue / PR / phase state.
- `/release <X.Y.Z>` — cut a versioned release (consolidates per-PR changelog fragments; SPEC §18).
- `/onboard-dir-mode [--tier 1|2|3] [--dry-run]` — install the v3 dir-mode substrate (labels, Issue templates, workflows, Project v2) into a target repo. Tier-aware, idempotent.

If a hook blocked you, start with [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) and [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md).

## Versioning

The shell version is stored in the top-level `VERSION` file as a single line of [semver](https://semver.org) 0.x — `MAJOR.MINOR.PATCH` with `MAJOR=0` throughout v0. Tags follow `v` + semver (e.g., `v0.2.0`).

```bash
claude-eng --version       # → prints VERSION-file contents (or `git describe` fallback)
```

`--version` is short-circuited before registry resolution and the scope guard, so it works from any cwd including unregistered paths.

**v0 conventions** (locked by Directive #122):

- Format is semver 0.x. Per [SemVer 2.0 §4](https://semver.org/#spec-item-4), 0.x carries no compatibility guarantees — bumps within 0.x are informational signals, not contracts.
- Bumping out of 0.x (to `1.0.0`) is reserved for the first non-self adopter dogfooding. No hook / CI / onboard enforces semver bump semantics at v0.
- Tags are pushed manually by the maintainer after a meaningful milestone merges to `main` (no per-PR cadence).

For change-authors: per-PR changelog fragments go under `changelog_unreleased/<category>/<N>.md` — see [`changelog_unreleased/TEMPLATE.md`](changelog_unreleased/TEMPLATE.md) and SPEC §18 (Release backbone) for the contract. [`CHANGELOG.md`](CHANGELOG.md) at repo root holds the consolidated history.

## Configuration toggles

All optional. Per-target state files live under `.claude/state/` (gitignored); env vars take priority when set.

| Knob | File | Env | Default | Purpose |
|---|---|---|---|---|
| Operating mode | `mode` | `CLAUDE_ENG_SHELL_MODE` | `attended` | `/ship` terminal behavior (§5.7.1) |
| Co-Authored-By trailer | `coauthor` | `CLAUDE_ENG_COAUTHOR` | `on` | Include the trailer in `/work-on` commits (§10.2) |
| Status cache TTL | — | `STATUS_CACHE_TTL` | `5` | Seconds before re-querying `gh` from `_status_collect` (§5.5) |
| Session-start fetch TTL | — | `SESSION_START_FETCH_TTL` | `21600` | Seconds before the shell-behind `git fetch` runs again (§6.5) |
| Session-start fetch timeout | — | `SESSION_START_FETCH_TIMEOUT` | `5` | Per-fetch `timeout(1)` bound when the TTL elapses (§6.5) |
| Commit-time lint timeout | — | `CLAUDE_ENG_LINT_TIMEOUT` | `30` | Bound on the commit gate's lint (§6.1) |
| Stop-hook throttle | — | `CLAUDE_ENG_STOP_THROTTLE` | `5` | Suggest `/review` every Nth response from the Stop hook (§6.3) |
| Unattended park log | — | `SHIP_PARK_LOG_PATH` | `.claude/state/unattended-park.log` | Where `/ship` appends park entries in `unattended` mode (§5.7.1) |
| PR cache repo override | — | `PR_CACHE_REPO` | — | Override the `owner/repo` `pr_cache` queries; falls back to `gh repo view` of the cwd (§5.4) |
| Behavioral smoke gate | — | `CLAUDE_ENG_BEHAVIORAL_SMOKE` | unset | Set to `1` to exercise live `directive-reviewer` in smoke §42e (SPEC §4.9.3); default-unset keeps smoke offline + deterministic |
| Dir-mode Project name | — | `CLAUDE_ENG_PROJECT_NAME` | `<repo-name> roadmap` (literal) | Override the dir-mode Project v2 title resolved by `scripts/setup_project.sh` and `scripts/dir_mode_project.sh resolve` (SPEC §1.7 Substrate guard) |

*`STATUS_CACHE_DIR_OVERRIDE` is internal-only (smoke-test plumbing for `helpers/status.sh`) and intentionally not listed.*

## Docs

- [MISSION.md](MISSION.md) — long-term direction and success criteria.
- [SPEC.md](SPEC.md) — the single self-contained specification (SSOT). Start from the TOC at the top.
- [docs/ENGINEERING_FLOW.md](docs/ENGINEERING_FLOW.md) — step-by-step engineering flow.
- [docs/SUBAGENTS.md](docs/SUBAGENTS.md) — subagent usage guide.
- [docs/ESCAPE_HATCH.md](docs/ESCAPE_HATCH.md) — bypassing hooks safely.
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) — common blocks and fixes.


## Verify

```bash
./scripts/test/smoke.sh           # ~350+ assertions across hooks, helpers, slash commands
./scripts/build_toc.sh --check    # SPEC.md TOC freshness
```
