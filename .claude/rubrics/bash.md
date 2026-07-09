# Bash idiom / readability rubric

> **Single source of truth** for the bash readability / language-idiom review axis.
> SPEC §4.5.1 references this file; it is **not** restated there (§9 thin-pointer discipline).
> `code-reviewer` (§4.5) reads this file **only when the diff contains bash** and applies
> its criteria as **advisory idiom-notes that never escalate to `block`** (SPEC §6.0 P1/P3 —
> a wrong "unidiomatic" verdict is ignorable at no cost, so the axis is advisory, not a gate).

This is the readability / language-idiom axis — **distinct from correctness**. Correctness ("does
it work") is already covered by `shellcheck --severity=warning` (the fail-closed CI gate, `scripts/lint.sh`),
by `code-reviewer`'s correctness/scope/security checks, and by the smoke suite. This rubric governs the
*other* senior-engineering quality dimension: **is the bash written the way bash wants to be written** —
readable, well-factored, and reaping the language's intended benefits.

## Deterministic-vs-LLM boundary

Each criterion is owned by exactly one of two mechanisms; the split is the boundary AC1 (#546) requires be explicit:

- **Deterministic** — *decidable by an existing tool or a fixed-string grep*. Runnable by the born-advisory,
  non-gating checker `scripts/lint_bash_idioms.sh` (never wired into the fail-closed CI lint gate — that would make
  idiom a hard block, violating the advisory face). These are surfaced mechanically, no judgment.
- **LLM-judgment** — *threshold or design judgment no linter should decide*. Applied by the `code-reviewer` LLM
  reading this rubric; not executed by the deterministic checker. Anchored by the worked-example pair below.

## Criteria

### 1. Quoting / array conventions — *deterministic (delegated)*
Unquoted expansions, word-splitting, and array-vs-string misuse are **already** covered by the pinned
`shellcheck` (SC2086, SC2206, SC2068, …) run by the CI gate at `--severity=warning`. **Reuse it, do not re-handroll**
(see the reuse scope note below). The idiom checker may invoke the *same pinned* shellcheck at a broader
advisory severity to surface softer style-level findings the gate does not block — never a second quoting engine.

### 2. `safe_source` discipline — *deterministic (grep)*
Every helper-to-helper and hook-to-helper source must go through `safe_source` (fail-open with an
`audit_log warn … helper-missing` on miss, SPEC §6.1), never a raw `source`/`.` of a helper path. A raw
`source helpers/foo.sh` (or `. helpers/foo.sh`) is flagged.

### 3. `git add -A` / `git add -u` prohibition — *deterministic (grep)*
Tree-mutating adds must be **path-scoped** (the implementer path-scoped-add discipline, SPEC §4.12). A bare
`git add -A` or `git add -u` is flagged — it can silently stage unrelated working-tree changes.

### 4. Function size / altitude — *LLM-judgment*
A function that mixes multiple altitudes (high-level orchestration interleaved with low-level string surgery),
or that has grown past the point where its name still describes all it does, should be split. This is a
**threshold judgment**, not a mechanical line count — it belongs to the reviewer, not the checker.

### 5. DRY across helpers — *LLM-judgment*
A fact, parse, or resolution re-implemented in a second site when a helper already exists (or should) is a
maintainability regression. Prefer extracting/reusing the shared helper.

### 6. Detection-by-attribute-combination where an explicit discriminator exists — *LLM-judgment*
**SMELL: detection-by-attribute-combination.** A fact that is *explicit somewhere* (a label, a parsed verb, a
normalized field) is re-inferred at each use site by combining several weak attributes (substring greps, flag
positions, body-line markers). Every new edge case then bolts *another* attribute onto a growing heuristic pile
instead of reading — or normalizing once to — the discriminator. The accretion **is** the smell.

**Idiomatic direction:** branch on the explicit discriminator, or **normalize once** to a canonical form and
branch on that — never re-derive the combination per call site. Flag both "this site re-derives a fact that is
explicit/normalizable elsewhere" and "a fix that adds a special-case to a growing attribute-combination (vs
normalizing) — a maintainability regression."

#### Worked example (the reviewer's few-shot anchor)

❌ **Unidiomatic (but correct)** — re-infers "is this a `gh pr merge`?" by combining weak attributes, and each
edge case bolts on another:
```bash
# attribute pile: substring + flag-scan + value-skip, re-derived at every call site
if printf '%s' "$cmd" | grep -q 'pr' \
   && printf '%s' "$cmd" | grep -q 'merge' \
   && ! printf '%s' "$cmd" | grep -q -- '--repo'; then
  is_merge=1   # next edge case → append yet another grep here
fi
```

✅ **Idiomatic** — normalize once to the parsed verb (the explicit discriminator), then branch on it:
```bash
verb="$(parse_gh_argv "$cmd")"   # canonical form, resolved once
if [ "$verb" = "pr-merge" ]; then
  is_merge=1
fi
```

The unidiomatic form is **correct** — it returns the right answer for the cases it enumerates — yet it is the
smell: the discriminator (`verb`) is explicit after normalization, so re-combining substrings per site is the
maintainability regression this axis exists to catch.

## Reuse, don't re-handroll (scope note, #276 / #490)

This rubric targets the underlying **design** and **new** code. It is **not** a call to rewrite battle-tested,
hardened resolvers (the `gh`-argv parser, the pinned-shellcheck resolver) mid-feature — those are **reused, not
re-handrolled** (the #276/#490 anti-drift precedent). Flag new code that re-derives what a hardened resolver
already yields; never flag the hardened resolver itself.
