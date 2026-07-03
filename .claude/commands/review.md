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
3. **Caller-side head-pin blind-compare (SPEC §4.5, #544)** — for a PR review, a worktree-isolated reviewer sits at the caller-chosen BASE and pins its own artifact to the PR head, reporting a first-line `reviewed-head: <sha>`. Compute the expected head yourself — `gh pr view <n> --json headRefOid --jq .headRefOid` — and **hold it privately: never pass it to the reviewer** (else the reviewer could echo it back for a tautological pass). Blind-compare each reviewer's independently-reported `reviewed-head` to your privately-held head; a mismatch/absent/unconfirmed head is a fail-closed invalid verdict (the reviewer reviewed a stale artifact, PR #543), reported as such — not a pass.
4. Combine the results and report. Don't auto-apply fixes unless the user asks.
