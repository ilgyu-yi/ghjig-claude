---
description: Use when the user asks a recall question ("have we addressed X before?", "what did we decide about Y?") OR when you internally hit a "have we decided this before?" beat before planning or a decision. Episodic retrieval over the project's own decision record (closed issues / merged PRs / ADRs); pointers only.
argument-hint: <topic>
---

`$ARGUMENTS` is the search topic.

Source `$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/recall.sh` and call `recall_pointers "$ARGUMENTS"`. That helper is the canonical implementation — see SPEC §5.25.

It answers "have we addressed this shape before?" by querying the **decision record** — closed issues (`gh search issues --state closed`), merged PRs (`gh search prs --state closed`), and ADRs (`docs/ADRs/*.md` title/H1 match) — and returns **pointers only**: one line per hit, a tag (`#` / `PR#` / `ADR-NNNN`) + number + the one-line title, **never a body**. Bounded by `RECALL_LIMIT` (default 5 per substrate, env-overridable). Fails open to a single `recall: decision record unavailable` line on any `gh`/grep error.

Use it before planning (or inside `/work-on`) to surface prior decisions; follow a pointer with a targeted read **only if relevant** — recall itself never injects bodies, preserving the narrowing safeguard (SPEC §5.25).
