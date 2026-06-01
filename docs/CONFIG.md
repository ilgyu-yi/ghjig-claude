# Configuration toggles

All optional. Per-target state files live under `.claude/state/` (gitignored); env vars take priority when set.

This table is the user-facing catalog for the shell's environment-variable and state-file knobs, kept in sync with the implementation under the Active SSOT-maintenance principle (SPEC §1.3): every env var documented elsewhere in the shell also appears here.

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
| Behavioral smoke gate | — | `CLAUDE_ENG_BEHAVIORAL_SMOKE` | unset | Set to `1` to exercise live `activation-reviewer` in smoke §42e (SPEC §4.9.3); default-unset keeps smoke offline + deterministic |
| Dir-mode Project name | — | `CLAUDE_ENG_PROJECT_NAME` | `<repo-name> roadmap` (literal) | Override the dir-mode Project v2 title resolved by `scripts/setup_project.sh` and `scripts/dir_mode_project.sh resolve` (SPEC §1.7 Substrate guard) |

*`STATUS_CACHE_DIR_OVERRIDE` is internal-only (smoke-test plumbing for `helpers/status.sh`) and intentionally not listed.*

The `§…` references point into [SPEC.md](../SPEC.md) — start from its Table of contents and read the targeted section with `Read --offset --limit`.
