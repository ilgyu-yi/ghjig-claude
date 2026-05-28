# Changelog

All notable changes to this project are recorded here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Version numbers follow [semver](https://semver.org/) 0.x (`MAJOR=0` throughout v0; see SPEC §3.5 and §18.4). The per-PR fragment contract for unreleased changes lives at [`changelog_unreleased/TEMPLATE.md`](changelog_unreleased/TEMPLATE.md); `/release X.Y.Z` consolidates the fragments into a new section here.

## [0.1.0] — 2026-05-26

Inaugural tagged release. Covers `init` through `v0.1.0` as a single block (per Directive #128 non-goal — no per-milestone backfill).

### Added

- Initial shell scaffolding — entry binary, bootstrap, injection, and registry of registered target paths. (#1)
- Hook system with five Claude Code event hooks (`PreToolUse` / `PostToolUse` / `Stop` / `UserPromptSubmit` / `SessionStart`) and fourteen helpers under `.claude/hooks/`. (#3)
- PR / issue / mission / ADR templates with section ownership and curate-on-commit discipline. (#5)
- Ten subagents — `planner`, `explorer`, `doc-writer`, `test-writer`, `code-reviewer`, `security-reviewer`, `issue-reviewer`, `plan-reviewer`, `directive-reviewer`, `triage-reviewer`. In `unattended` mode the six reviewers substitute for human-confirm checkpoints. (#7, #44)
- Slash commands — `/onboard`, `/file-issue`, `/work-on`, `/sync-pr`, `/status`, `/review`, `/ship`, `/adr`, `/audit`. (#9)
- CI workflow (`.github/workflows/ci.yml`) with syntax (`bash -n` + `shellcheck`) and smoke jobs across a dual-OS matrix (`ubuntu-latest` + `macos-latest`). (#13, #17, #21)
- Dir-mode v0 — Final Goal → Directive → Execution Issue layer with `directive-reviewer` subagent, five dir-mode commands (`/file-directive`, `/activate-directive`, `/list-directives`, `/link-directive`, `/complete-directive`), and type-aware engineering hooks. (#42, #43, #44, #45, #46)
- Dir-mode commands `/revise-directive` and `/block-directive` for in-place Directive body edits and Blocked-state lifecycle. (#78, #80)
- `/reflect` skill posts a Directive-progress comment on the parent Directive after each Execution PR merges. (#47, #57)
- `/triage` skill — binary accept/reject classifier for `needs-triage` / `status:proposed` Issues, backed by `triage-reviewer`. (#94)
- Discussion-tier Issues (`/discuss`, `/resolve-discussion`) — friction-free filing for "weird but not a bug" observations; bypasses the rationale-triad gate. (#112, #116)
- `/onboard-dir-mode` tier-aware target-substrate installer (tier 1 / 2 / 3) — installs the 10-label v3 set, Issue templates, workflows, and Project v2 into adopting target repos via a PR (ADR-0004). (#114, #118)
- User-global memory carve-out — Edit/Write under `$HOME/.claude/` is allowed by the registry / scope guard so the auto-memory tier works without weakening the shell's user-global-isolation contract. (#91)
- Filer-aware mutation invariants — `trusted-filer-mutate` hook arm blocks `gh issue close` on a trusted-filer Issue without `--reason completed` and blocks `gh issue edit --remove-label directive` on any filer. (#95)
- `dir-mode-post-merge` GitHub Actions workflow runs Directive-status maintenance (Active → Completed via `/complete-directive`, Status field mirroring) on every Execution PR merge. (#63)
- `claude-eng --version` short-circuited before registry resolution, sourcing from the top-level `VERSION` file with `git describe --tags` fallback. (#123)
- Annotated tag `v0.1.0` marking the first tagged release (`v` + semver convention locked by Directive #122). (#126)

### Changed

- Dir-mode v3 substrate reframe (ADR-0003) — collapsed the Goal-as-Item Project artifact into doc-as-code `MISSION.md`; Issues are the SSOT, Project v2 is a derived view; Directives use a four-state lifecycle (Proposed / Active / Blocked / Completed) encoded as labels with the Project Status field mirrored by `issues-to-project-mirror.yml`. (#96)
- Audit log format v3 — structured JSON-line format with stable field ordering and category/event tokens audit-callers can grep. (#108)
- AC-closeout matcher skips when every closing issue carries the `directive` label — Directives complete via `/complete-directive`, not AC checkboxes. (#46)

### Fixed

- macOS 3.2 bash compatibility — removed `globstar` and equivalent bash-4-only patterns; smoke + syntax run identically on Linux and macOS legs. (#17)
- Shellcheck warnings across hooks and helpers — real bugs plus justified inline silences in `.shellcheckrc`. (#21)
- Secret-scan emits per-line `<file>:<line>: <pattern-id>` markers and honors a `.shellsecretignore` allow-list at the target-repo root (gitignore-narrow). (#25)
- `SessionStart` banners cover two silent-no-op states: shell injected without `CLAUDE_ENG_SHELL_ROOT` set, and `CLAUDE_ENG_SHELL_ROOT` set but `hookrt.sh` missing. (#23, #37)
- `safe_source` utility centralizes hook-to-helper and helper-to-helper sourcing; missing helpers fail-open with one `audit_log warn <category> helper-missing` record. (#31, #34, #36)
- Matcher pass-through invariant — `pass_through_trace` audits every `pre_tool_use.sh` matcher that fell through without a decided state; high-frequency happy paths call `mark_allow` for silent ack. (#33)
- AC-closeout race / misfire fixes — split `gh pr merge` and `ac_closeout.sh` invocations to avoid GitHub API propagation latency. (#83, #29, #31)
- `setup_project.sh` reconciles `SINGLE_SELECT` options additively on re-run; preserves user-added options. (#76)
- Post-v3 drift sweep — README subagent counts, MISSION-fit narratives, and skill metadata aligned to the v3 substrate flip. (#120)

### Security

- Sensitive-file editing (`.env`, `*.pem`, `credentials*`) blocked by `PreToolUse` hook regardless of carve-outs. (#3, #25)
- Staged-diff scan for known secret formats (AWS, GitHub, GitLab, OpenAI/Anthropic, Slack tokens, password literals). (#25)
- Shell audit log never persists diff bodies — only structured records of decisions, categories, and reasons. (#3)

[0.1.0]: https://github.com/ilgyu-yi/claude-eng-shell/releases/tag/v0.1.0
