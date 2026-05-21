---
description: Invoke code-reviewer (+ security-reviewer if relevant).
argument-hint: [--staged | <base>]
---

Parse `$ARGUMENTS`:
- `--staged`: review staged diff only.
- `<base>` as commit-ish: review from base to HEAD.
- No argument: default base (origin/main or PR base) to HEAD.

Steps:
1. Invoke `code-reviewer` subagent with diff + changed-file context + target `MISSION.md` + referenced issue body + PR body as input.
2. If the diff touches a security surface (auth/session/input/deps/crypto/IO boundary), invoke `security-reviewer` as well.
3. Combine the results and report. Don't auto-apply fixes unless the user asks.
