---
description: One-time check right after cloning a target repo. Reports on upstream, permissions, SSOT, .github/, branch protection, CI.
---

Perform an initial check of the target repo. **No automatic changes.** All recommendations are for the user to review and execute.

Report in order:

1. **Upstream check**: `gh repo view --json isFork,parent`. If it's a fork, block with a message and stop.
2. **Permission check**: `gh repo view --json viewerPermission`. If push permission (`ADMIN`/`MAINTAIN`/`WRITE`) is missing, advise and stop.
3. **Target SSOT check**: one line per file:
   - `MISSION.md` (absent → strong warning + draft proposal based on `$CLAUDE_ENG_SHELL_ROOT/.claude/templates/mission.md`)
   - `SPEC.md` — the project's behavioural contract (SPEC §1.3, the frequently-consulted pair with MISSION). Required **once the project has an external contract** (CLI/API/schema/protocol); a project with no external surface yet legitimately has none. Absent **and** the project has an external contract → warn + draft proposal based on `$CLAUDE_ENG_SHELL_ROOT/.claude/templates/spec.md` (a lightweight scaffold — the shell never authors the contract content). The ToC-freshness CI gate (`check-toc.yml`) ships with the tier-3 dir-mode substrate (`/onboard-dir-mode`).
   - `README.md`
   - `CLAUDE.md`
   - `docs/ARCHITECTURE.md`
4. **`.github/` check**:
   - `.github/ISSUE_TEMPLATE/` present? If absent → propose installing `$CLAUDE_ENG_SHELL_ROOT/.claude/templates/issue_template_for_target.md`.
   - `.github/PULL_REQUEST_TEMPLATE.md` present? If absent → propose installing `$CLAUDE_ENG_SHELL_ROOT/.claude/templates/pr_template_for_target.md`.
   - `.github/CODEOWNERS` present? If absent → recommend.
5. **Branch protection**: `gh api repos/{owner}/{repo}/branches/main/protection`. Report missing items (PR required, review required, status checks required, force push blocked). Setup requires admin so print commands only.
6. **CI presence**: check `.github/workflows/`. If absent → recommend appropriate workflows.

Each item gets ✓ or ✗ and a one-line summary. End with a "Recommended next actions" block.
