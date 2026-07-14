---
description: Run code-reviewer on a PR and post its verdict as a first-class, commit_id-pinned GitHub review. Producer-only — adds/changes/removes no merge gate (SPEC §5.29; Issue #585, Directive #584).
argument-hint: "<pr>"
---

Materialize a `code-reviewer` verdict as a **first-class GitHub review**, `commit_id`-pinned to the reviewed head. `/file-review <pr>` is a **general capability** (any PR, any time) *and* the **producer** the #586 merge-review gate will later consume. It is **producer-only**: it adds, changes, or removes **no** merge gate, and it does not touch `/ship`, `permissions.allow`, or SPEC §5.7.1 (those are #586 / #587, out of scope). See SPEC §5.29 for the contract.

## Procedure

0a. **Validate `<pr>`** — accept only a bare number matching `^[0-9]+$`, **or** a trusted `github.com/<owner>/<repo>/pull/<n>` URL (extract `<n>` from the URL). Any other argument → abort with `"/file-review: <pr> must be a PR number or a github.com pull URL"`, post nothing. The `<pr>` value is untrusted input — it is never interpolated into a shell command before this validation passes.

0b. **Repo-scope guard** — resolve the origin repo (`gh repo view --json nameWithOwner --jq .nameWithOwner`) and confirm the PR targets it (compare against the PR's `headRepositoryOwner`/base repo from `gh pr view`). A **cross-repo** target (the PR is not on the origin repo):
   - **attended** → surface the mismatch and confirm with the user before proceeding.
   - **unattended** → **refuse, fail-closed** — abort, post nothing, audit `aborted` (there is no human to confirm; a cross-repo review is out of the mandate).

0c. **Preflight** — `gh pr view <pr> --json number,author,headRefOid,baseRefName,state,url`. A gh-auth failure or not-found → abort and post **nothing** (audit `aborted`). Never post a review you could not preflight.

1. **Compute the head PRIVATELY** — `HEAD_SHA=$(gh pr view <pr> --json headRefOid --jq .headRefOid)`. **Never pass `HEAD_SHA` to the reviewer** (SPEC §4.5, #544): the reviewer must resolve and report the head independently, else it could echo yours back for a tautological pass. Hold it privately for the blind-compare (step 4) and the `commit_id` pin (step 7).

2. **Resolve ownership** — the acting identity `ME=$(gh api user --jq .login)` and the PR author `AUTHOR=$(gh pr view <pr> --json author --jq .author.login)`. `own := (ME == AUTHOR)`. GitHub 422s a self `APPROVE`/`REQUEST_CHANGES`, so ownership selects the submission event in step 7.

3. **Invoke `code-reviewer`** (worktree-isolated, SPEC §4.5) on the PR diff + changed-file context + target `MISSION.md` + the referenced issue body + the PR body. If the diff touches a **security surface** (auth/session/input/deps/crypto/IO boundary), also invoke `security-reviewer` (parity with `/review`, §5.6). A `security-reviewer` **block composes**: any security block → overall `verdict=block`, regardless of the code-reviewer grammar.

4. **Blind-compare the head** — each reviewer reports a first-line `reviewed-head: <sha>` it derived independently. Blind-compare it to the privately-held `HEAD_SHA`. If the reviewed head **cannot be confirmed equal** to the private head — a mismatch, an absent `reviewed-head:`, or an unresolvable head — the review ran against a stale/unknown artifact (PR #543). In that case **post nothing** and audit `invalid`, then abort. This arm **fails closed to silence, not to a block**: `/file-review` never posts a `block` / `REQUEST_CHANGES` on a head it could not blind-compare (an unearned negative verdict on an unknown artifact).

5. **Map the verdict** (over `code-reviewer`'s `ship` / `ship after fix` / `block` grammar):
   - `ship` → **approve**
   - `ship after fix` / `block` (or a composed security block) → **block**
   - (the unconfirmed / unresolvable head is already handled in step 4 → post nothing / `invalid`.)

6. **Build the body in a sanitized temp file** — write the review body to a `mktemp` file (the `activate.md` / `reflect.md` `--body-file` idiom); **never** inline-interpolate reviewer or PR text into a shell / `gh` argument. Sanitize before writing:
   - **Whole-body `@mention` neutralization** — neutralize **every** `@mention` anywhere in the body (e.g. backtick-quote or zero-width-break the `@`), not just leading ones, so the posted review cannot mass-ping.
   - A **human-readable verdict line** stating approve / block and a one-line summary of the reviewer finding.
   - **Own-PR only:** append the machine-readable marker (below) as the last line. On another author's PR the marker is **omitted** — the native `APPROVE`/`REQUEST_CHANGES` event *is* the machine-readable signal there.
   - `rm` the temp file after submission (step 7).

   **Marker contract** (own-PR `COMMENT` review **body only** — never the PR body or a PR comment). The exact token, byte-identical to SPEC §5.29:

   ```
   <!-- file-review verdict=<approve|block> head=<HEAD_SHA> reviewer=code-reviewer -->
   ```

   `verdict=approve` derives **only** from a real `code-reviewer` `ship` and is **never hand-written**. `head=` is redundant human/grep convenience that must equal the review's `commit_id`; `reviewer=code-reviewer` records the engine. #586 reads its authoritative fields (`commit_id`, `author.login`) from the attested review **object**, and only `verdict` from this marker text.

7. **Submit `commit_id`-pinned via REST** — bind the privately-confirmed head as `commit_id` and read the body from the temp file:

   ```bash
   gh api repos/{owner}/{repo}/pulls/<n>/reviews \
     -f commit_id="$HEAD_SHA" \
     -f event=<APPROVE|REQUEST_CHANGES|COMMENT> \
     --field body=@<tempfile>
   ```

   - **Another author's PR:** `event=APPROVE` (approve) / `event=REQUEST_CHANGES` (block) — the direct `gh api` call above.
   - **Own PR:** `event=COMMENT` (GitHub 422s a self approve/request-changes); the body carries the marker.
     - **Own PR that is the CURRENT branch's PR (the `/ship` self-merge case) → route through the wrapper (#598):** the raw `gh api …/reviews` self-approve POST is blocked by the auto-mode classifier as self-approval (SPEC §5.7.1). Submit the `COMMENT` via the fixed-form, `permissions.allow`-covered wrapper instead, feeding the sanitized body on **stdin** (never an inline argument):
       ```bash
       printf '%s' "$REVIEW_BODY" | .claude/ghjig-root/scripts/ghjig_file_review_post.sh
       ```
       The wrapper resolves the current-branch PR + head itself, **fails closed unless the acting identity == the PR author**, and hardcodes `event=COMMENT` — so it needs no positional args and its allow entry is the exact wildcard-free `Bash(.claude/ghjig-root/scripts/ghjig_file_review_post.sh)`. Use the direct `gh api` REST call above **only** for another author's PR, or a manual self-review of a **non-current** PR (not the classifier-blocked own-current-PR shape).

   `gh pr review` is **deliberately not used** — it cannot pin a `commit_id`, so a push concurrent with the review would rebind the verdict to an unreviewed head (the §4.5 head-pin failure). Binding `commit_id` to the blind-confirmed head means a racing push leaves the review pinned to a now-stale commit, which #586 correctly reads as not-current. Do **not** submit via an inline body argument — the body always travels via `--field body=@<tempfile>` (direct call) or **stdin** (wrapper).

8. **Audit** — source the hook runtime (`. ".claude/ghjig-root/.claude/hooks/hookrt.sh"`) then record under the **`file-review`** category (event-info; free-form reason text):
   - posted: `audit_log info file-review posted "pr=#<N> verdict=<approve|block> commit_id=$HEAD_SHA ownership=<self|other> event=<APPROVE|REQUEST_CHANGES|COMMENT>"`
   - unconfirmed head (step 4): `audit_log info file-review invalid "pr=#<N> reason=unconfirmed-head commit_id=<reviewed-or-unknown>"`
   - preflight / scope abort (steps 0b/0c): `audit_log info file-review aborted "pr=#<N> reason=<preflight|cross-repo-unattended>"`

9. **Output** the posted review (verdict, event, `commit_id`) and a verification hint: `gh pr view <pr> --json reviews`.

## Edge cases

- **Own PR + `ship`** → a `COMMENT` review carrying `verdict=approve` in the marker (never an `APPROVE` — GitHub 422s a self-approve). The approve signal for #586 is the marker `verdict`, bound to the attested review's `commit_id` and `author.login`.
- **Concurrent push during review** → the review stays pinned to the now-stale `commit_id`; #586 reads it as not-current and does not treat it as a live approval. `/file-review` does not re-review — the `commit_id` binding makes a re-review loop unnecessary.
- **Unresolvable head** (gh down mid-run, `reviewed-head:` absent) → post **nothing**, audit `invalid`, abort. Never a block on an unknown artifact.
- **Cross-repo PR in unattended mode** → refuse, fail-closed; post nothing.
- **Security-surface diff** → `security-reviewer` also runs; any security block composes into an overall `block` even if `code-reviewer` said `ship`.

## Forbidden

- Hand-writing a marker `verdict=` value — `verdict=approve` comes **only** from a real `code-reviewer` `ship`, never authored by hand.
- Submitting via `gh pr review` (it cannot pin a `commit_id`) — always the `commit_id`-pinned REST `pulls/<n>/reviews` call.
- Passing the reviewer / PR text as an inline body argument — the body always travels via a written, sanitized temp file (`--field body=@<tempfile>`); untrusted text is never interpolated into a `gh` argument, and every `@mention` is neutralized.
- Adding, changing, or removing any merge gate, or touching `/ship` / `permissions.allow` / SPEC §5.7.1 — `/file-review` is **producer-only** (#586 / #587 own those).
- Posting a `block` / `REQUEST_CHANGES` on a head that could not be blind-compared to the private PR head — that arm posts nothing and audits `invalid`.

## Work language

Author the **review body** (verdict line, finding summary) in the **work language** — `resolve_work_lang` (SPEC §5.7.2), not necessarily the conversation language. Before authoring, recast the reviewer output into the work language; your chat replies to the user stay in the communication language. Default (unset) is `en`.
