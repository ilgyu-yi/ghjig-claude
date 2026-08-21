# ADR 0007: The /file-review marker carries Directive #639's attributable reject count — the only substrate durable across a fresh clone

- Date: 2026-08-21
- Status: Accepted
- Context PR: #691

## Context

Directive #639 needs a **per-change attributable reject count** so a repeatedly-rejected method is forced to change rather than re-submitted unchanged (the 8-round loop). This is the MISSION "The mechanism" enforcement dual: a block that names no alternative is a one-sided regression, so a repeated block must escalate into a forced change of approach, and that escalation needs a count it can read.

The count needs a store. Any candidate substrate must satisfy **three criteria**:

1. **Attributability** — the count attributes to **one change** (a reviewed head), not to a whole PR. Two distinct fixes on the same PR must not share one counter, and a re-submission of the *same* rejected approach must land on the *same* counter.
2. **Cross-round durability** — the count is readable at the **next round's start**, and that next round may run in a **new session** or from a **fresh clone**. A substrate that only exists in the local working tree of the session that wrote it fails here.
3. **Degrade-record independence** — when the substrate is unreadable, the degrade record that reports the unreadability must **not** write to the channel whose unreadability it is reporting. A substrate and its own failure-notice must fail independently, or the notice is lost with the thing it describes.

The decisive mechanical fact for criterion 2: `.claude/ghjig-state/` and `.claude/audit/` are **git-excluded** — `git check-ignore` resolves both, and neither contributes tracked files, so the audit log is **absent from a fresh clone**. Any audit-log-based or local-state-based substrate therefore fails cross-round durability precisely at the fresh-clone boundary, which is exactly the boundary the next round may cross.

## Decision

Adopt **substrate (i)**: the `/file-review` marker

```
<!-- file-review verdict=<approve|block> head=<HEAD_SHA> reviewer=code-reviewer -->
```

materialized as the **body of a `commit_id`-pinned GitHub review object** (submitted via `gh api …/pulls/<n>/reviews` with `commit_id` bound to the blind-confirmed head, read back via `gh pr view <pr> --json reviews`; SPEC §5.29). In #639 **item 2** — not in this unit — the marker is extended to carry a **reason class**.

Selection reasoning:

- **Durability (the criterion that eliminates the others).** Substrate (i) is the only candidate whose store is **external to the git-excluded local tree**: the review object is GitHub-hosted, keyed by PR number. It survives a new session and a fresh clone, so it passes cross-round durability across the boundary that kills (ii)/(iii)/(iv).
- **Attributability.** The marker is **head-pinned** (`head=<HEAD_SHA>`, equal to the review's `commit_id`), giving attribution **finer than a PR** — per reviewed change. Simultaneous same-head invocations (the SPEC §4.11 `N=3` case) collapse to one round on the **shared `commit_id`**, so concurrency does not inflate the count.
- **Degrade-record independence.** When the review-object read fails, the degrade record lands in the **audit log** — a channel independent of GitHub review-object readability. This is the same structural argument that makes `blast_radius.sh`'s degrade-to-single-reviewer sound (SPEC §4.11): classifier and log fail **independently**, so the notice is not lost with the thing it describes.
- **It also closes #639's substrate-gap item 2 structural zero.** On a self-authored PR there is no native `REQUEST_CHANGES` event to count (GitHub 422s a self-`REQUEST_CHANGES`); the block signal is the **marker text in a `COMMENT` review body**, so reading the marker — not counting native events — is what makes self-authored PRs countable at all.

This ADR's **own merge** is a SPEC §4.11 `irreversible-adr` high-asymmetry-gated change (`N=3`), which under #639's round-derivation collapses to round 1 on its shared head.

## Alternatives considered

The framing "since `.claude/ghjig-state/` and the audit log are git-excluded, **all four** candidates fail durability" is **wrong**. It is true only for (ii)/(iii)/(iv), which read local git-excluded state. Substrate (i) **escapes** because it reads remote GitHub state keyed by PR number, not local tree state. No fifth option (a committed in-tree per-change record) is needed, because (i) already satisfies all three criteria.

| Candidate | Attributability | Cross-round durability | Degrade-record independence |
|---|---|---|---|
| **(i)** `/file-review` marker on a `commit_id`-pinned GitHub review object | **PASS** — head-pinned (`commit_id`), per-change | **PASS** — GitHub-hosted, survives fresh clone / new session | **PASS** — degrade record in the audit log, a channel independent of review-object readability |
| **(ii)** extend the #361 reason-class trail (`reviewer_reject_audit`) to `code-reviewer` | FAIL — record is issue-keyed (`class=… issue=#N`), no head | FAIL — the trail **is** the git-excluded audit log, absent from a fresh clone | FAIL — substrate = audit log = the degrade channel (one event) |
| **(iii)** extend the `audit_log info file-review posted` record with a class field | PASS — carries `commit_id` | FAIL — git-excluded audit log | FAIL — same channel as its own degrade record |
| **(iv)** consume `promotion_candidates.sh`'s category×class aggregation | FAIL — global `group_by([category,class])`, no PR/head dimension; `code-reviewer` absent from the trail | FAIL — reads the git-excluded audit log | FAIL — same channel |

Per-candidate rejection detail:

- **(ii) extend the #361 `reviewer_reject_audit` trail to `code-reviewer`** (SPEC §6.1). FAIL attributability — the record is **issue-keyed** (`class=… issue=#N`), carrying no head, so it cannot attribute to one change on a multi-change PR. FAIL durability — the trail **is** the git-excluded audit log, absent from a fresh clone. FAIL independence — the substrate and its degrade record are the same channel (one event). It also **injects `code-reviewer` blocks into `promotion_candidates.sh`'s advisory-to-hook-promotion report**, where a block is not an ignored advisory — a category error.
- **(iii) extend the `audit_log info file-review posted` record with a class field** (`.claude/commands/file-review.md`, §5.29). PASS attributability (it carries `commit_id`) but FAIL durability (git-excluded audit log) and FAIL independence (the record shares the channel with its own degrade record).
- **(iv) consume `promotion_candidates.sh`'s category×class aggregation.** FAIL attributability — a **global** `group_by([category,class])` with no PR/head dimension, and `code-reviewer` is absent from the trail it reads. FAIL durability — it reads the git-excluded audit log, and it is a cross-session hook-promotion advisory, not a per-change in-flow signal. FAIL independence — same channel.

## Consequences

- **Positive.** The reject count is **durable across a fresh clone / new session** (criterion 2), **per-change attributable** by head (criterion 1), and **independently degradable** (criterion 3). It reuses an existing materialized artifact rather than adding a new store, and it makes self-authored PRs countable via the marker text where no native `REQUEST_CHANGES` event exists.
- **How (i) satisfies the discriminating criterion (independence).** The count lives in a GitHub review object; its unreadability is reported to the audit log. Read and degrade-notice channels fail independently — the same independent-failure precedent that makes `blast_radius.sh`'s degrade-to-single-reviewer sound (SPEC §4.11). This is the criterion (ii)/(iii)/(iv) each fail, and the one that decides the choice.
- **Negative / accepted residuals — both belong to #639 item 2, not this unit:**
  - **(a) The marker carries no reason class yet.** As stated it carries `verdict` but no class, so item 2 must extend it with a `class=<reason-class>` field. The extension must be **additive**: the #586 merge-review gate parses `verdict` (and reads `commit_id`/`author.login` from the review **object**) from the marker, and must not break — a new field added alongside `verdict` leaves that parse intact.
  - **(b) Coverage depends on the gating round going through `/file-review` materialization.** A round that runs `code-reviewer` inline via `/review` without materializing a review deposits **no countable marker**. So item 2's ladder-owning callers (`/review`, `/ship`) must ensure **each gating round materializes** a review. This is the intended coverage semantics: the count counts materialized gating rounds.

## Notes

- Execution Issue #690; Parent Directive #639 (substrate-gap items 1–3).
- Related surfaces (cite by anchor / arm / §, never line number): `.claude/commands/file-review.md` (SPEC §5.29 — marker, posted audit record, `--json reviews` read path); `.claude/hooks/helpers/reviewer_audit.sh` (#361 reason-class trail, SPEC §6.1); `scripts/promotion_candidates.sh` (category×class aggregation); `.claude/hooks/helpers/blast_radius.sh` (SPEC §4.11 — independent-failure degrade precedent); MISSION "The mechanism" (the enforcement dual).
- Downstream, out of scope here: the substrate implementation and the additive `class=` marker field (#639 item 2); the ladder / carrier / scope / degrade (items 3–6).
