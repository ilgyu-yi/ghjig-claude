---
description: Surface an execution-layer finding to an upstream Initiative as a structured comment — a challenge (re-evaluation requested) or a completion (termination assessment requested). Comment-only; never edits/rejects/closes the Initiative.
argument-hint: "<initiative-#> {--challenge \"<reason>\" | --completion}"
---

Surface a finding from the execution layer **up** to an Initiative (SPEC §1.7 "Feedback is upward and non-deciding"). One command, two modes (mirrors `/resolve-discussion`'s two-path shape). The execution layer reports information the planning layer structurally cannot have, and **requests** a decision — it never makes one.

**The shell consumes Initiatives; it never authors, edits, closes, relabels, or retires them.** The only write this command makes is a single `gh issue comment` (allowed by `initiative-readonly`, §6.1). Both modes lead the comment with a **scannable marker** (`## Initiative challenge` / `## Initiative completion`, modeled on `## AC closeout`) so an upstream consumer could parse it, and pass the body via `--body-file` (write to a `mktemp` file, `rm` after) so extracted/upstream text is never interpolated into a `gh` argument position.

## Procedure

0. **Substrate preflight**: abort with `"target lacks dir-mode substrate; run /onboard-dir-mode --tier 2 first"` if `gh label list | cut -f1 | grep -qx initiative` fails. Fail-open on `gh` network errors.

1. **Type / location check** — resolve `#N`; require the `initiative` label (`gh issue view <N> --json labels`). If `#N` is not an Initiative, abort with `"#N is not an Initiative — /initiative-feedback operates only on Initiatives"`. Same-repo only (cross-repo Initiatives are out of scope, SPEC §1.7).

2. **Mode dispatch** — exactly one of `--challenge "<reason>"` or `--completion` is required (error if both or neither).

### `--challenge "<reason>"`

Use when **execution reality contradicts the Initiative** — the termination condition looked measurable but isn't, or extraction hit a real dependency / measurability gap / implementation cost the planning layer could not see. Post a comment (via `--body-file`):

```
## Initiative challenge

From an execution standpoint this Initiative appears not to hold, for code-derived reasons the planning layer cannot have on its own:

<reason — the actual dependency / measurability / cost, with the concrete execution evidence>

Re-evaluation requested. (This is an escalation from the execution layer, not a decision — the Initiative is not rejected, retired, or closed; whether to revise, defend, or retire it stays with the upstream owner.)
```

This **escalates** — it mirrors a reviewer `block` escalating rather than auto-discarding (§4.9.1). It does NOT reject, retire, edit, or close the Initiative. The shell does not track what the upstream does next. Audit `initiative-feedback` decision=`challenge`.

### `--completion`

Use when the Directives extracted from this Initiative (`/consume-initiative`, §5.21) **have all landed** (merged). Post a comment (via `--body-file`):

```
## Initiative completion

The Directives extracted from this Initiative have landed:

<evidence — the merged Directives / PRs, what each delivered toward the termination condition>

Termination assessment requested. (This reports execution completion and requests the upstream owner assess whether the termination condition is met — the shell does not assert it is met and does not close the Initiative; that judgment stays upstream.)
```

It reports the fact and **requests** termination assessment. It does NOT assert the termination condition is met and does NOT close the Initiative (asserting completion is a strategic judgment that stays upstream — the same logic that forbids rejection). Audit `initiative-feedback` decision=`completion`.

3. **Output**:
   ```
   Posted <challenge|completion> on Initiative #<N>: <comment-url>
   (Escalated upward — the decision stays with the upstream owner.)
   ```

## Operating mode

Same in attended and unattended — surfacing a structured comment upward is a generation act, not a gated decision (the *decision* is the upstream's, by design). No reviewer gate.

## Escape

No reviewer-gate escape (there is no reviewer gate). The `initiative-readonly` matcher permits `gh issue comment`, so no `SKIP_HOOKS` is needed for normal use.

## Forbidden

- **Never edit, close, reopen, relabel, or retire the Initiative** — comment-only (`initiative-readonly`, §6.1). 
- **Never reject or retire** an Initiative via a challenge — challenge *escalates*, it does not decide.
- **Never assert the termination condition is met** or close the Initiative via a completion — it *requests* termination assessment; the upstream owner decides.
- Never post without the scannable `## Initiative {challenge,completion}` marker (an upstream consumer scans for it).
- Never interpolate upstream/extracted text into a `gh` argument position — use `--body-file`.
