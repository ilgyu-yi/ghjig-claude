# Engineering Flow

Full details in [SPEC.md §2](../SPEC.md).

```
[Project start / joining]
  ./scripts/setup.sh <local-path | repo-url>   ← single entry: deps → register-or-clone → onboard → dir-mode gate (default N) → next command (--enter execs claude)
  /onboard                   ← check target SSOT, .github/, permissions, branch protection
       │
       ▼
[Start a work item]
  /file-issue <short description>   ← if needed, create the issue with goal + acceptance criteria
       │
       ▼
  /work-on <issue#>           ← pull upstream, create branch, call planner, create draft PR
       │
       ▼
[planner agent] plan + checklist. User approval required.
       │
       ▼
[Phase A: Doc]   commit: docs(#N): ...
       ▼
[Phase B: Test]  commit: test(#N): ... (intentional failure)
       ▼
[Phase C: Code]  commit: feat(#N): ... / fix(#N): ...
       ▼
[Mid-checkpoint] /status, /review as needed
       ▼
[/ship]   resolve mode → review → security (conditional) → doc sync → tests → curate PR body → verify Closes → issue AC closeout → CI → gh pr ready
       │
       ├── mode = attended (default) → stop at "ready"
       │       ▼
       │   [Human review + merge]   on merge, issue auto-closes, branch auto-deletes
       │
       └── mode = unattended → classify blocker (see SPEC §5.7.1)
               ├── clean → `gh pr merge --auto --merge --delete-branch`
               ├── soft  → one self-fix-and-push, then wait
               └── hard  → comment + label `unattended-parked` + log, stop
```

## Phase order — relaxation

| Type | Relaxation |
|------|-----------|
| `fix` | reproduce-failing-test → code → (if needed) doc |
| `refactor` | skip doc when external behavior unchanged |
| `perf` | measure → code → doc (report results) |
| spike | free on a separate branch, restructure into a proper PR before merge |
| typo / obvious fix | a single commit is fine |

Strict for: `feat`, `docs`, external contract / API / schema changes.
