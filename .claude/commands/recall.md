---
description: Use when the user asks a recall question ("have we addressed X before?", "what did we decide about Y?") OR when you internally hit a "have we decided this before?" beat before planning or a decision. Episodic retrieval over the project's own decision record (closed issues / merged PRs / ADRs); pointers only. The optional deep tier (--deep) also searches issue COMMENT bodies and routes ONLY on explicit user intent (natural-language "search the comments" / "we surely decided this", or an explicit --deep) — it is NOT part of the pre-planning reflex; never trigger the deep comment sweep as a reflex.
argument-hint: <topic>
---

`$ARGUMENTS` is the search topic.

Source `$CLAUDE_ENG_SHELL_ROOT/.claude/hooks/helpers/recall.sh` and call `recall_pointers "$ARGUMENTS"`. That helper is the canonical implementation — see SPEC §5.25. Pass the `--deep` flag through (`recall_pointers "$ARGUMENTS" --deep`) **only on explicit user intent** — a natural-language "search the comments" / "we surely decided this", or a literal `--deep`. Deep is off by default; never route it as the pre-planning reflex.

It answers "have we addressed this shape before?" by querying the **decision record** — closed issues (`gh search issues --state closed`), merged PRs (`gh search prs --state closed`), and ADRs (`docs/ADRs/*.md` title/H1 match) — and returns **pointers only**: one line per hit, a tag (`#` / `PR#` / `ADR-NNNN`) + number + the one-line title, **never a body**. Bounded by `RECALL_LIMIT` (default 5 per substrate, env-overridable). Fails open to a single `recall: decision record unavailable` line on any `gh`/grep error.

Use it before planning (or inside `/work-on`) to surface prior decisions; follow a pointer with a targeted read **only if relevant** — recall itself never injects bodies, preserving the narrowing safeguard (SPEC §5.25). The deep tier (`--deep`) widens the sweep to issue **comment** bodies (fixed-string match, so dotted tokens like `3.12` survive) but stays pointers-only — it emits the matched issue's `#<n> title`, never the comment text — and remains explicit-intent-only.
