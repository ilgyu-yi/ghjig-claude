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

Render each line as ✓ (`ok`) or ✗ (`fail`) with its one-line detail. A fork (`upstream fail`) or missing push permission (`permission fail`) is a **hard stop** — the shell is upstream-only and needs push; advise and stop before the judgment steps.

## Judgment steps (prose — not delegated)

These need authoring judgment and the MISSION scaffold-not-author boundary, so they stay here rather than in the fact-reporting script:

1. **SSOT authoring.** `SPEC.md` is **required for any project that carries code** — it is the behavioural SSOT (SPEC §1.3), not gated on an external contract. If `ssot:SPEC.md` came back `fail`, treat authoring it as the **first thing to fix, before other work**: prompt the user to write `SPEC.md`, offering the lightweight scaffold `.claude/ghjig-root/.claude/templates/spec.md` (the shell scaffolds the slot; it never authors the contract content). Likewise for `ssot:MISSION.md fail`, offer `.claude/ghjig-root/.claude/templates/mission.md`. Note `README.md`, `CLAUDE.md`, `docs/ARCHITECTURE.md` if absent (reference SSOT — recommend only).
2. **`.github/` proposals.** If absent, propose installing the templates (the tier-3 dir-mode substrate install via `/onboard-dir-mode` owns the full path):
   - `.github/ISSUE_TEMPLATE/` → `.claude/ghjig-root/.claude/templates/issue_template_for_target.md`
   - `.github/PULL_REQUEST_TEMPLATE.md` → `.claude/ghjig-root/.claude/templates/pr_template_for_target.md`
   - `.github/CODEOWNERS` → recommend.
3. **Branch protection setup.** If `branch-protect` is `fail`, print the setup commands only (setup requires admin) — do not apply them.

Each rendered item gets ✓ or ✗ and a one-line summary. End with a "Recommended next actions" block, leading with SPEC authoring when `ssot:SPEC.md` failed.
