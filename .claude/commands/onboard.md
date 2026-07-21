---
description: One-time check right after cloning a target repo. Reports on upstream, permissions, SSOT, .github/, branch protection, CI.
---

Perform an initial check of the target repo. **No automatic changes.** All recommendations are for the user to review and execute.

## Mechanical checks (delegated)

The mechanical present/absent facts are produced by one shared script — the single source, also consumed by `scripts/setup.sh`, so the two never carry divergent copies of the check logic (SPEC §9). Run it from the target repo's cwd:

```bash
GR="$(git rev-parse --show-toplevel 2>/dev/null)/.claude/ghjig-root"
[ -e "$GR/.claude" ] || { echo "GHJig: not inside a registered project (cd to the project root, or run scripts/register.sh)"; exit 1; }
"$GR/scripts/lib/onboard_checks.sh"
```

It emits one `<check> ok|fail <detail>` line per check on stdout and always exits 0 (it reports facts, it never gates):

- `upstream` — fork detection (`ok` = not a fork; `fail` = a fork — the shell is upstream-only).
- `permission` — push permission (`ok` = `ADMIN`/`MAINTAIN`/`WRITE`).
- `ssot:MISSION.md` / `ssot:SPEC.md` — presence of the frequently-consulted SSOT pair (SPEC §1.3).
- `branch-protect` — branch protection on the default branch (PR required, review required, status checks, force-push blocked); `fail` also covers the no-admin / unreadable case.
- `ci` — presence of `.github/workflows/`.
- `toc-format` — SPEC.md's ToC *form* (gh-free): `ok` for a marker line-number ToC (or SPEC absent), `fail` for a marker-less / anchor-link ToC (recommend `--migrate`, or number headings / add markers by hand) or corrupt markers (repair). This is a **FORMAT check, not a freshness check** — `toc-format ✓ ≠ check-toc CI green`; ToC freshness stays the `check-toc.yml` CI gate's job (SPEC §1.3).
- `docs-pointer` — `docs/*.md` thin-pointer discipline (gh-free): `ok` when every docs file leads with a `SPEC` reference (first two non-empty lines); `fail` lists offenders (SPEC §9).

Render each line as ✓ (`ok`) or ✗ (`fail`) with its one-line detail. A fork (`upstream fail`) or missing push permission (`permission fail`) is a **hard stop** — the shell is upstream-only and needs push; advise and stop before the judgment steps.

## Judgment steps (prose — not delegated)

These need authoring judgment and the MISSION scaffold-not-author boundary, so they stay here rather than in the fact-reporting script:

1. **SSOT authoring.** `SPEC.md` is **required for any project that carries code** — it is the behavioural SSOT (SPEC §1.3), not gated on an external contract. If `ssot:SPEC.md` came back `fail`, treat authoring it as the **first thing to fix, before other work**: prompt the user to write `SPEC.md`, offering the lightweight scaffold `.claude/ghjig-root/.claude/templates/spec.md` (the shell scaffolds the slot; it never authors the contract content). Likewise for `ssot:MISSION.md fail`, offer `.claude/ghjig-root/.claude/templates/mission.md`. Note `README.md`, `CLAUDE.md`, `docs/ARCHITECTURE.md` if absent (reference SSOT — recommend only).
2. **`.github/` proposals.** If absent, propose installing the templates (the tier-3 dir-mode substrate install via `/onboard-dir-mode` owns the full path):
   - `.github/ISSUE_TEMPLATE/` → `.claude/ghjig-root/.claude/templates/issue_template_for_target.md`
   - `.github/PULL_REQUEST_TEMPLATE.md` → `.claude/ghjig-root/.claude/templates/pr_template_for_target.md`
   - `.github/CODEOWNERS` → recommend.
3. **Branch protection setup** (tier-3, SPEC §6.7, §5.1 step 5). Surface the granular server-side state — run the tier-3 verifier and report each facet, then **prescribe** the exact SET commands. Unlike the tier-2 activation in step 4, `/onboard` **never auto-SETs** tier-3: asserting all-actor server authority is high-cost-if-wrong (SPEC §6.0), so it stays report+prescribe behind human execution.

   ```bash
   "$GR/scripts/install_branch_protection.sh" --check      # classify the five facets: configured/partial/absent/unreadable
   "$GR/scripts/install_branch_protection.sh" --prescribe  # print the exact gh api / UI commands (setup requires admin)
   ```

   Report each facet (PR required, review required at head, required status checks, force-push blocked, direct-push/deletion blocked) with its state, plus the `bypass_actors`/`enforce_admins` surface — a tier the setting admin can bypass is authority for non-those-actors only (SPEC §6.7). The coarse `branch-protect` line above is the boolean glance; this verifier is the granular tier-3 surface.
4. **Local git-hook tier activation** (SPEC §6.7, §5.1 step 7). Unlike the recommend-only steps above, this is the **one activation `/onboard` performs** — it is repo-local and reversible, so it respects the §3.4 user-global boundary. Install and verify the committed `.githooks/` enforcement tier:

   ```bash
   "$GR/scripts/install_git_hooks.sh"          # sets repo-local core.hooksPath=.githooks
   "$GR/scripts/install_git_hooks.sh" --check  # confirm activation (non-zero = still inert)
   ```

   Report ✓ when `--check` exits 0, ✗ otherwise. Reversible any time with `git config --unset core.hooksPath` (or `scripts/install_git_hooks.sh --uninstall`). A clone that never runs this stays inert until the SessionStart drift arm re-surfaces it (SPEC §6.7).

Each rendered item gets ✓ or ✗ and a one-line summary. End with a "Recommended next actions" block, leading with SPEC authoring when `ssot:SPEC.md` failed. Also fold in any failing doc-shape fact check (step 8, SPEC §5.1):

- `toc-format fail` — if the ToC is marker-less / anchor-link, recommend `build_toc.sh --migrate`, but **only** when the SPEC already uses numbered `## N.` headings and a canonical `## Table of contents` block; otherwise number the headings (`## N. Title`) or add the `<!-- TOC START -->`/`<!-- TOC END -->` markers by hand first. If the markers are corrupt, recommend repairing them. Note that `toc-format` is a **FORMAT check, not a freshness check** — it says nothing about whether the ToC is up to date; ToC freshness is the `check-toc.yml` CI gate's job (SPEC §1.3).
- `docs-pointer fail` — recommend leading each offending `docs/*.md` with a "Full details in SPEC §…" reference so it stays a thin pointer, not a parallel copy of the contract (SPEC §9).
