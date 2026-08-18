# Citation profile fixture: a proposed Issue body (#676)

<!--
Smoke fixture for scripts/lint_citations.sh (SPEC section 1.10), read by section
174b of scripts/test/smoke.d/70-gates-contentlocks.sh. Not a real Issue: an
excerpt written in this corpus's own citation style, carrying one span per
outcome class, two of them defective by construction.

Per span, left to right: the attribution, then what the reader must return.

  1. .claude/agents/finding-judge.md   plain-delimited, present at that file  -> resolves
  2. scripts/lint_bash_idioms.sh       star-delimited, present at that file   -> resolves
  3. scripts/lint_bash_idioms.sh       real wording, only in CHANGELOG.md     -> site-mismatch
  4. .claude/agents/issue-reviewer.md  wording no artifact carries            -> unresolved
  5. an Issue comment, no path         GitHub artifact, not in the tree       -> unresolvable-locally
  6. .claude/agents/code-reviewer.md   under the four-word floor, not a span  -> not extracted
  7. no attribution on the line        schematic placeholder                  -> no-attribution
  8. inside a fenced block             quoted draft line, not body prose      -> not extracted

Spans 6 and 8 are the two silent bounds: each lands as a second defect line if
the four-word floor or the fence exclusion is dropped -- span 6 as a second
unresolved, span 8 as a second site-mismatch (its wording is carried by the smoke
file that asserts it is never extracted) -- so 174b's defect counts measure both. This comment carries no quotation marks on purpose --
the reader extracts by delimiter and does not special-case HTML comments.
-->

## What

The shell binds its judges and reviewers to evidence-with-command, and binds the **author** of a durable-artifact body to nothing comparable on the axis that decides whether the body's claims are real.

- `.claude/agents/finding-judge.md:60` — "A verdict with no command is not a verdict" — the judge is bound to run what it reports.
- The idiom reader states its own posture at `scripts/lint_bash_idioms.sh:22` — *"findings print to stdout and the exit code is always 0"*.
- `scripts/lint_bash_idioms.sh` is quoted in the parked draft as *"never a block, never wired into the fail-closed CI lint gate"* — the wording is real, the site it is hung on is not.
- `.claude/agents/issue-reviewer.md` is summarised as requiring *"the reviewer re-derives every quoted span before the verdict line"*, a sentence the draft supplied and no artifact carries.
- The first-round review comment on `#676` reads *"two defects the audit could not see"*, which lives in a GitHub comment and nowhere in the working tree.
- `.claude/agents/code-reviewer.md` names the axis *"advisory idiom notes"* rather than a gate.
- The acceptance line is still schematic: *"one verifiable condition per acceptance criterion"* — nothing is named for it yet.

The parked draft's own citation, quoted verbatim for the record:

```text
- `SPEC.md:1265` — *"the wording blended from two sources in the parked draft"*
```

## Why

Reviewer rounds spent on defects a pre-dispatch command decides are hours the MISSION cost clause does not allow for.
