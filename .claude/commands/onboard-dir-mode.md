---
description: Install the dir-mode substrate (labels + Issue templates + workflows + Project) into a target repo. Tier-aware. Idempotent. PR-based file installs (SPEC §1.7 Substrate-in-target contract).
argument-hint: [--tier 1|2|3] [--dry-run]
---

Install the dir-mode substrate into the current target repo (cwd). Three-tier model (SPEC §1.7 Substrate-in-target contract):

- **Tier 1**: no install — eng-mode works without the dir-mode substrate.
- **Tier 2**: install the 13-label dir-mode set via `gh label create --force`. Unlocks `/file-directive` / `/activate-directive` / `/complete-directive` directly against Issues. No Project mirror.
- **Tier 3**: tier 2 + install ISSUE_TEMPLATE files + workflow files via a PR to the target + create Project v2 via `gh project create` + populate fields via `scripts/setup_project.sh`. Unlocks the template chooser + Project-as-derived-view. (`/triage` is a deprecated alias for `/activate` as of #173; raw label-free filings are auto-stamped `status:proposed`+`task` by `auto-status-proposed.yml`, #179.)

Each tier is a strict superset. Re-running is idempotent at every step.

## Procedure

1. **Parse `$ARGUMENTS`** — `--tier <1|2|3>` (default 3) + optional `--dry-run` (no mutations; print would-do). Other values → error.

2. **Verify target context** — must be in a registered target repo (per `scripts/register.sh`). If cwd not in registry: error. If not a git repo: error.

3. **Resolve target's owner/repo** via `gh repo view --json owner,name --jq '"\(.owner.login)/\(.name)"'`.

4. **Tier 1**: print confirmation that no install is needed; exit.

5. **Tier 2** (label install):
   - Invoke `bash .claude/ghjig-root/scripts/onboard_target.sh --tier 2` (idempotent — uses `gh label create --force`).
   - Verify via `gh label list` that all 13 labels exist: `directive`, `initiative`, `status:proposed`, `status:blocked`, `awaiting-author`, `task`, `execution`, `discussion`, `P0`, `P1`, `P2`, `P3`, `skip-changelog` (`initiative` — #249 — marks the planning-tier Initiative consumed from upstream, SPEC §1.7; `execution` — #186 — labels an Execution Issue parented under a Directive; `awaiting-author` — #172 — marks the reviewer→author handoff after a `revise`/trusted-reject; `skip-changelog` is the documented PR-time opt-out for the release-backbone fragment-gate per SPEC §18.6). This set is the canonical 11 installed by `scripts/ensure_v3_labels.sh` plus the inline `directive` and `initiative` from `scripts/onboard_target.sh`.

6. **Tier 3** (full substrate):
   - Run step 5 (tier 2 prerequisite).
   - Invoke `bash .claude/ghjig-root/scripts/onboard_target.sh --tier 3`:
     - Copies canonical files from `.claude/ghjig-root/.claude/templates/target-substrate/` into target's `.github/`:
       - `ISSUE_TEMPLATE/{config,directive-proposal,execution-under-directive,task,bug-report,discussion}.yml`
       - `workflows/{auto-status-proposed,auto-clear-awaiting-author,issues-to-project-mirror,dir-mode-post-merge,check-changelog,check-toc,check-ssot-home}.yml` — `check-changelog.yml` is the release-backbone fragment-gate (SPEC §18.6); blocks PRs to `main` / `*-maintenance` that lack a `changelog_unreleased/<category>/<N>.md` fragment unless the `skip-changelog` label is applied. `check-toc.yml` is the SPEC ToC-freshness gate (SPEC §1.3); on PRs that touch `SPEC.md` it runs `build_toc.sh --check --spec SPEC.md` and fails if the Table of contents is stale — it **skips clean when the target has no `SPEC.md`** (a project with no external contract legitimately has none). `check-ssot-home.yml` is the SSOT-home discipline gate (SPEC §1.3), at parity with the shell's internal smoke §91; it fails a `docs/*.md` that does not lead with a `SPEC` reference (thin-pointer rule) and fails when the docs lead with an anchored `SPEC §` pointer while `SPEC.md` is absent or a stub (SSOT-presence rule) — it **skips clean when the repo is contract-less** (no SPEC and no docs claiming one).
       - `workflows/build_toc.sh` — the SPEC ToC generator/checker `check-toc.yml` runs (byte-identical to the canonical `scripts/build_toc.sh`); shipped alongside the workflow like the dir-mode-post-merge sourced helpers.
       - `workflows/check-ssot-home.sh` — the pure-bash SSOT-home checker `check-ssot-home.yml` runs (after `actions/checkout`); shipped alongside the workflow, the same sibling pattern as `build_toc.sh`.
     - Also copies the **release-backbone authoring substrate** into the target **repo root** (not `.github/`): `changelog_unreleased/TEMPLATE.md` + the six Keep-a-Changelog category subdirectories (`added/ changed/ deprecated/ removed/ fixed/ security/`) each with a `.gitkeep` placeholder. This is the authoring affordance the `check-changelog.yml` gate enforces against — full contract in SPEC §18.6 / §18.1.
     - Creates branch `onboard-dir-mode-substrate`, commits the files, pushes, opens a PR via `gh pr create --title "chore: onboard GHJig-Claude dir-mode substrate"` — **target maintainer reviews + merges**.
     - Direct push to target's `main` is forbidden (protected-branch hook fires; PR-based install is the canonical path — SPEC §1.7 Bootstrap path).
   - Project v2 setup: invoke `bash .claude/ghjig-root/scripts/setup_project.sh` (idempotent — creates the Project if absent, reconciles fields if present).

7. **Audit log** — `audit_log info onboard-dir-mode created "target=<owner>/<repo> tier=<N>"`.

8. **Output**:
   ```
   Onboarded <owner>/<repo> to tier <N>.
   Tier-2 (labels): <K> labels installed.
   Tier-3 (PR): <pr-url> opened — maintainer to review + merge.
   Tier-3 (Project): <project-url>.
   ```

## Idempotency contract

- Re-running with the same tier produces no new artifacts: labels via `--force` overwrite-without-error; ISSUE_TEMPLATE / workflow files re-committed are no-op if `git diff` is empty (the install script `git diff --quiet` checks before committing).
- Downgrades are out-of-scope (the maintainer reverts manually per the reversibility paths in SPEC §1.7).

## Operating mode

- **attended**: each tier step prints the action and waits for confirmation.
- **unattended**: auto-applies all steps; logs every install as an audit line.

## Escape

`SKIP_HOOKS=onboard-dir-mode SKIP_REASON='<why>' /onboard-dir-mode <args>` bypasses the install entirely (use for sandbox/test contexts where the substrate would interfere).

## Forbidden

- Direct push to target's `main` branch (protected-branch hook enforces this).
- Installing files outside the target's `.github/` (the canonical-substrate allow-list is the typed boundary; SPEC §1.7 Substrate-in-target contract).
- Auto-deleting target files (uninstall is the maintainer's call; SPEC §1.7 Reversibility contract names the manual commands).
- Skipping the audit log (the trail is the foundation for `/audit` queries).
