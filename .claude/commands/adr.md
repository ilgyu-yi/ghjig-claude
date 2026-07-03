---
description: Write an Architecture Decision Record in the target repo. For irreversible decisions only.
argument-hint: <title>
---

`$ARGUMENTS` is the ADR title.

**ADR vs PR body Decisions**:
- ADR — irreversible, system-level. DB engine change, API spec, auth scheme, etc. Once merged, costly to reverse.
- PR body Decisions — reversible, PR-scoped. Default option choice, library preference, etc. Explained within this PR.

Confirm with the user that this decision warrants an ADR. If yes:

1. Check `docs/ADRs/` exists (else confirm creation permission).
2. Determine the next number: `ls docs/ADRs/ 2>/dev/null | grep -oE '^[0-9]+' | sort -n | tail -1`, then +1, zero-padded to 4 digits.
3. Create `docs/ADRs/NNNN-<kebab-title>.md` from `.claude/ghjig-root/.claude/templates/adr.md`.
4. Add a link `→ ADR-NNNN: <title>` to the current PR body's Decisions section.
