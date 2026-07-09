# Python idiom / readability rubric

> **Single source of truth** for the Python readability / language-idiom review axis.
> SPEC §4.5.1 references this file; it is **not** restated there (§9 thin-pointer discipline).
> `code-reviewer` (§4.5) reads this file **only when the diff contains Python** and applies
> its criteria as **advisory idiom-notes that never escalate to `block`** (SPEC §6.0 P1/P3 —
> a wrong "unpythonic" verdict is ignorable at no cost, so the axis is advisory, not a gate).

This is the readability / language-idiom axis — **distinct from correctness**. Correctness ("does
it work") is what `pytest`, `ruff`, and type-checkers (`mypy`/`pyright`) cover. This rubric governs the
*other* senior-engineering quality dimension: **is the Python written the way Python wants to be written** —
readable, well-factored, and reaping the language's intended benefits.

## Deterministic-vs-LLM boundary

Each criterion is owned by exactly one of two mechanisms; the split is the boundary AC1 (#546) requires be explicit:

- **Deterministic** — *decidable by an existing linter*: PEP 8 / formatting, unused imports & undefined names,
  mutable-default-argument (`def f(x=[])`), bare-`except:`. These are the Python analog of bash's delegated
  `shellcheck` and are owned by **ruff / flake8 / pyflakes** — the language's own linter, not a re-handrolled engine.
  **A Python deterministic checker script (the `scripts/lint_bash_idioms.sh` analog) is NOT provided by this repo** —
  this repo has no Python code and no pinned Python linter, so the checker is **deferred** until a bound Python repo
  needs it. The deterministic criteria are *named* here so a future checker/reviewer knows the boundary, but they are
  **delegated to the language's own linter**, never re-handrolled here.
- **LLM-judgment** — *design/idiom judgment no linter should decide*. Applied by the `code-reviewer` LLM
  reading this rubric; not executed by any deterministic checker. Anchored by the worked-example pair below.

## Criteria

### 1. PEP 8 / formatting & naming — *deterministic (delegated to ruff/black)*
Line length, whitespace, import ordering, and `snake_case`/`CapWords` naming conventions are **already** decidable
by `ruff`/`black`. **Reuse them, do not re-handroll** (see the reuse scope note below) — never a second formatter.

### 2. Unused imports / undefined names / mutable default args / bare `except:` — *deterministic (delegated to ruff/pyflakes)*
Unused imports, references to undefined names, mutable default arguments (`def f(x=[])`, `def f(x={})`), and a
bare `except:` that swallows everything are all owned by `ruff`/`pyflakes`. Flagged mechanically by the linter, no judgment.

### 3. EAFP over LBYL / duck typing — *LLM-judgment*
Prefer "easier to ask forgiveness than permission" (`try/except`) over pre-checking every precondition (look-before-you-leap).
Don't over-guard with `hasattr(...)`/`isinstance(...)` chains where duck typing suffices — reach for the attribute and
handle the exception, rather than interrogating the object first. This is a **design judgment**, not a mechanical check.

### 4. Comprehensions & generators — *LLM-judgment*
A list/dict/set comprehension or a generator expression is usually clearer than a manual loop-and-`append` or an
index-accumulation loop. Prefer the comprehension when it reads at a glance; fall back to an explicit loop only when
the body is too complex to stay readable inline.

### 5. Context managers (`with`) for resource lifetimes — *LLM-judgment*
Use a **context manager** (`with open(...) as f:`, `with lock:`) for anything with a lifetime — files, locks, sockets,
transactions — instead of a manual open/close or a hand-rolled `try/finally`. The `with` block ties release to scope
and survives early return and exceptions.

### 6. Idiomatic iteration — *LLM-judgment*
Iterate directly: `enumerate` for index+value, `zip` for parallel sequences, `.items()`/`.values()` for mappings,
tuple unpacking for structured elements. Flag `range(len(...))` index bookkeeping and manual counter variables where
a direct iteration form reads better.

### 7. Structured data — *LLM-judgment*
Prefer a `dataclass`, `NamedTuple`, or `enum.Enum` over ad-hoc dicts, positional tuples, or string constants for
records and closed sets of values. A named field or enum member documents intent and lets tooling check it; a bare
dict/tuple/string re-invents that at every use site.

### 8. Type hints as contracts — *LLM-judgment*
Annotate public function signatures and dataclass fields. A **type hint** expresses the intended contract (what goes
in, what comes out), not decoration — it lets type-checkers and readers verify assumptions. Flag public APIs whose
signatures leave the contract implicit where a hint would carry real intent.

### 9. Type-by-attribute-combination where an explicit discriminator exists — *LLM-judgment*
**SMELL: type-by-attribute-combination.** A fact that is *explicit somewhere* (a class, an `Enum`, a discriminant
field) is re-inferred at each use site by combining weak attribute checks — `hasattr(...)` piles, `isinstance` chains,
`type(x).__name__` string sniffing. Every new case then bolts *another* check onto a growing heuristic pile instead
of dispatching on the explicit discriminator. The accretion **is** the smell.

**Idiomatic direction:** dispatch on the explicit type/enum — polymorphism, `functools.singledispatch`, a `match`
statement, or a discriminant field — or **normalize once** to a canonical form and branch on that. Never re-derive
the combination per call site. Flag both "this site re-derives a fact that is explicit/normalizable elsewhere" and
"a fix that adds a special-case to a growing attribute-combination (vs normalizing) — a maintainability regression."

#### Worked example (the reviewer's few-shot anchor)

❌ **Unpythonic (but correct)** — re-infers "what kind of shape is this?" by combining `hasattr`/`isinstance` checks,
re-derived at every call site, and each new shape bolts on another branch:
```python
# attribute pile: hasattr + isinstance, re-derived at every call site
def area(shape):
    if hasattr(shape, "radius") and isinstance(shape.radius, (int, float)):
        return 3.14159 * shape.radius ** 2
    elif hasattr(shape, "width") and hasattr(shape, "height"):
        return shape.width * shape.height   # next shape → append yet another branch here
```

✅ **Pythonic** — dispatch on the explicit discriminator (here polymorphism; `enum` + `match` or
`functools.singledispatch` are equally idiomatic), resolved once at the definition site:
```python
class Shape:
    def area(self) -> float: ...

class Circle(Shape):
    def __init__(self, radius: float) -> None: self.radius = radius
    def area(self) -> float: return 3.14159 * self.radius ** 2

class Rect(Shape):
    def __init__(self, width: float, height: float) -> None:
        self.width, self.height = width, height
    def area(self) -> float: return self.width * self.height

# call site: no attribute sniffing — dispatch on the explicit type
total = sum(s.area() for s in shapes)
```

The unpythonic form is **correct** — it returns the right answer for the cases it enumerates — yet it is the
smell: the discriminator (the shape's type) is explicit at construction, so re-combining `hasattr`/`isinstance`
checks per call site is the maintainability regression this axis exists to catch.

## Reuse, don't re-handroll (scope note, #276 / #490)

This rubric targets the underlying **design** and **new** code. It is **not** a call to rewrite battle-tested,
hardened libraries (the standard library, a mature parsing/HTTP/serialization package) mid-feature — those are
**reused, not re-handrolled** (the #276/#490 anti-drift precedent). Flag new code that re-derives what a mature
library already yields; never flag the library itself.
