# claude-eng-shell

An operating shell for [Claude Code](https://docs.claude.com/claude-code) that runs on top of the standard GitHub workflow. See [SPEC.md](SPEC.md) for the full specification — start from the **Table of contents** at the top of that file and `Read --offset --limit` into the section you care about rather than loading all ~1,300 lines.

## Core ideas

- **GitHub-standard backbone** — every change rides issue → branch → draft PR → checklist commits → ready PR → merge. Default base is `main`; topic-branch / experimental work picks an alternate via `/work-on --base <branch>` (SPEC §10.5).
- **Doc → Test → Code work order** — strict for `feat`/`docs`/contract changes; relaxed for `fix`/`refactor`/`perf` per SPEC §1.2.
- **Active SSOT maintenance** — docs change alongside code; merged PR bodies are durable cross-session memory via SessionStart.
- **Two operating modes** — **eng-mode** handles engineering execution (issue → PR → merge); **dir-mode** handles directing maintenance (Final Goal → Directive → Execution Issue). Same workflow pattern (generate → review → gated approval → audit), different artifact types and reviewer. Manual mode switching in v0 — orchestration is v1+ (SPEC §0.4 / §1.7 / §2.1).
- **Ten subagents** — `explorer`, `planner`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `directive-reviewer`, `triage-reviewer`. The six reviewers (`code-`, `security-`, `issue-`, `plan-`, `directive-`, `triage-`) substitute for human-confirm checkpoints in `unattended` mode.
- **Hooks enforce discipline** — protected branches, force push, backmerges (`git merge main` on a feature branch), secret exposure, malformed commits, sensitive files, paths outside the registry, `gh pr merge` when a linked issue has unchecked AC and no `## AC closeout` comment (`/ship` step 7.6 invokes `scripts/ac_closeout.sh` to satisfy by construction). Every block is escapable via `SKIP_HOOKS=<category> SKIP_REASON='<why>'` and audit-logged at `.claude/audit/audit.jsonl`. Secret-scan hits emit `<file>:<line>: <pattern-id>` markers and honor a `.shellsecretignore` allow-list at the target-repo root (SPEC §6.1 / §7 — the structural tuning mechanism for repeated false positives, preferred over normalizing `SKIP_HOOKS=secret`). SessionStart warns when a workspace was injected but launched via plain `claude` instead of `claude-eng` (otherwise every hook would silently no-op — see SPEC §6.5(c)).

## Install

```bash
git clone <this-repo-url> claude-eng-shell
cd claude-eng-shell
./scripts/bootstrap.sh
```

`bootstrap.sh` only checks dependencies — `git`, `gh`, `jq` are required; `python3` is recommended (used by several helpers; missing python falls back to less-precise behavior). It never modifies `~/.zshrc` or any other user-global file. Add the binary to PATH or alias it yourself:

```bash
export PATH="$PWD/bin:$PATH"
# or
alias claude-eng="$PWD/bin/claude-eng"
```

### Versioning

The shell version is stored in the top-level `VERSION` file as a single line of [semver](https://semver.org) 0.x — `MAJOR.MINOR.PATCH` with `MAJOR=0` throughout v0. Tags follow `v` + semver (e.g., `v0.2.0`).

```bash
claude-eng --version       # → prints the VERSION-file contents (or `git describe` fallback)
```

`--version` is short-circuited before registry resolution and the scope guard, so it works from any cwd including unregistered paths.

**v0 conventions** (locked by Directive #122):
- Format is semver 0.x. Per [SemVer 2.0 §4](https://semver.org/#spec-item-4), 0.x carries no compatibility guarantees — bumps within 0.x are informational signals, not contracts.
- Bumping out of 0.x (to `1.0.0`) is reserved for the first non-self adopter dogfooding. No hook / CI / onboard enforces semver bump semantics at v0.
- Tags are pushed manually by the maintainer after a meaningful milestone merges to `main` (no per-PR cadence).

For change-authors: per-PR changelog fragments go under `changelog_unreleased/<category>/<N>.md` — see [`changelog_unreleased/TEMPLATE.md`](changelog_unreleased/TEMPLATE.md) and SPEC §18 (Release backbone) for the contract. [`CHANGELOG.md`](CHANGELOG.md) at repo root holds the consolidated history.

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

For **dir-mode** (SPEC §1.7), bootstrap the GitHub Project v2 substrate from inside a registered target repo:

```bash
./scripts/setup_project.sh         # idempotent — creates "<repo-name> roadmap" with
                                    # 6 fields and links to the repo. On re-run,
                                    # reconciles SINGLE_SELECT options additively
                                    # (preserves user-added options). The Iteration
                                    # field is user-added via the GH UI (gh CLI lacks
                                    # the ITERATION data-type). Schema locked by
                                    # docs/ADRs/0002-…
```

## Operating modes

| Mode | `/ship` terminal behavior | Use |
|---|---|---|
| `attended` (default) | stops at PR-ready | human reviews + merges |
| `unattended` | continues to merge (clean) or park (hard blocker) | overnight runs, batched fixes |

Set per-target with `echo unattended > .claude/state/mode`. Override per-invocation with `/ship --mode=unattended`. See SPEC §5.7.1 for the full resolution priority and blocker classification.

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
