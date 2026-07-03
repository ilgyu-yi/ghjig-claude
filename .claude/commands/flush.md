---
description: Pre-clear flush — distill task-scoped session state into durable memory so a context clear is active → archived, not active → delete. (SPEC §3.7 / §5.24)
argument-hint: ""
---

The **flush** half of the `flush → clear → reconstruct` context lifecycle (SPEC §3.7). Run this **before** you clear the working context. It distills the reconstructable core of the current task into durable memory so that the clear is an **active → archived** transition rather than `active → delete` — the operational form of MISSION's "active → archived, not active → deleted" invariant.

`/flush` **does not and cannot invoke** Claude Code's native `/clear` — the native command is outside the shell boundary (SPEC §3.4). This skill *precedes* a clear and makes it safe by guaranteeing an archive exists first; the matching **reconstruct** half is SessionStart session restore (SPEC §6.5(b)), which re-injects the durable memory on the next session. Trigger is **explicit only** (you or a skill invoke it); threshold automation is deferred (SPEC §0.4 / §3.7).

## Procedure

1. **Resolve the task-scoped state.** Source `.claude/ghjig-root/.claude/hooks/helpers/status.sh` and call `status_compact` (the canonical projection — same fields the `UserPromptSubmit` hook and `/status` use, so the archive and the reconstruct read identically): branch, issue, PR, phase, `next:` step, mode, shell-root, state, work-lang.

2. **Write at least one durable-memory artifact** (the archive). In priority order:
   - **PR body** — when the current branch has a PR, curate it per the PR-as-living-doc rule (SPEC §1.4): fold the current phase, the `next:` step, and any decision taken since the last commit into the PR body (refetch the remote body first; abort the auto-update if it changed externally, per `/sync-pr`). This is the richest task-scoped artifact.
   - **`.claude/state/` flush record** — always write this (a branch may have no PR yet, so the PR body alone has a hole). Source `.claude/ghjig-root/.claude/hooks/hookrt.sh` and write `status_json` to `"$(ghjig_state_dir)/flush-record.json"` (the per-project ephemeral state dir, SPEC §3.2.2). This is the always-available durable target.
   - **GitHub artifacts** — for anything narrative that belongs on the durable record (a design note, an open question), append a `gh issue comment` / `gh pr comment` rather than letting it die with the context.

   The flush must produce or update **at least one** durable artifact, so the state is recoverable after the clear.

3. **Report what was archived**, then tell the user it is now safe to clear with the native `/clear`. Name the artifacts written (PR #, flush-record path) so the user can verify the archive before discarding the context.

## Known gap (SPEC §3.7)

SessionStart restore (SPEC §6.5(b)) currently re-injects the PR body, the referenced issue body, and a `/status` snapshot — it does **not** yet read the `.claude/state/flush-record.json` written here. So when a PR exists, reconstruct is complete; on a branch with no PR yet the record is written (the archive exists) but is not auto-re-injected. Closing that gap is a follow-up; until then, prefer landing a draft PR early so the PR body carries the archive.

## Operating mode

- **attended**: propose the flush targets (the PR-body edit + the flush record) for confirmation before writing.
- **unattended**: write the targets automatically (reviewer-substitution model, SPEC §1.5), then report.

## Forbidden

- Invoking or simulating Claude Code's native `/clear` — `/flush` only archives; the human clears.
- Reporting "flushed" without having written at least one durable artifact.
- Overwriting a PR body that changed on the remote since the last fetch (external-edit conflict — abort, per `/sync-pr`).

## Work language
Author every durable artifact this skill writes — the PR-body edits, any `gh` comment, and human-readable fields in the flush record — in the **work language** (`resolve_work_lang`, SPEC §5.7.2), not necessarily the conversation language. Your chat report to the user stays in the communication language. Default (unset) is `en`.
