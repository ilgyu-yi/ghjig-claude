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
3.5. **Finding judgment — dispatch `finding-judge` (SPEC §4.13, §5.6)** — once step 3 has resolved *which* artifact was reviewed, route `code-reviewer`'s finding set through `finding-judge` **before the author acts on any finding**. A review that returned **no findings pays no dispatch** — fall through to step 4.
   - **Dispatch shape**: a **fresh, worktree-isolated `finding-judge` invocation per round, with no shared context**. Pass the PR number, `code-reviewer`'s findings **verbatim** (what the reviewer actually wrote, never a paraphrase), and the reviewer identity; record `dispatch:` — which invocation produced the findings and which produced the judgment, since the judge cannot self-observe that limb. **Never hand-carry the prior round's judged list into the prompt** — the judge fetches it itself; hand-carrying it through the caller's context reintroduces the interested party into the judge's input. Do not restate the judge's output schema here — `.claude/agents/finding-judge.md` is the contract SSOT (§9).
   - **Durable before the fix**: post the judged list to the PR as **one comment per round**, carrying the canonical marker, **before** the author writes any fix. Post it via `gh pr comment <n> --body-file <tempfile>` with whole-body `@mention` neutralization — the sanitized-temp-file idiom `.claude/commands/file-review.md` (and `activate.md` / `reflect.md`) already use; never inline-interpolate reviewer text into a `gh` argument.
   - **No-PR path (`--staged`, or a local `<base>`)**: there is no PR and therefore no durable substrate. The judge declares `durable: none (<mode>)` **explicitly** rather than silently dropping the ordering — the ordering binds *list vs fix*, not *comment vs fix*, so the judged list is still complete before the first fix is written.
   - **Non-conversion**: the judge **never converts** a reviewer's verdict token — a `block` still stops the ship on `/ship`'s side, and here the reviewer's verdict is reported as the reviewer wrote it. The judge emits no `ship`/`approve`/`block` token of its own, so it is not a vote. What changes is only what the author receives: a judged, durable list instead of raw reviewer prose. **No merge gate is added** — the `gh pr merge` gates are untouched.
   - **Fail open, loudly**: if the judge is unavailable or returns malformed output, proceed on the **raw findings** exactly as before, record `judgment: unavailable`, and emit an `audit_log warn`. **Never park** — parking would convert an advisory authoring aid into a blocker.
   - `/review` needs **no restructure** of its own: it has no blocker-stop, so step 3.5 sits before step 4 on every path and is reachable for every finding set.
4. Combine the results and report. Don't auto-apply fixes unless the user asks.
