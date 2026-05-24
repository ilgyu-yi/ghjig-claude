---
description: List Directives filtered by Status (default omits Completed). Read-only; tabular output (SPEC §5.11).
argument-hint: [--status <state>] [--iteration <name>]
---

List Directives in the dir-mode Project filtered by `Status` and optionally `Iteration`.

## Procedure

1. **Resolve the Project** — same as `/file-directive` step 1.

2. **Parse arguments**:
   - `--status <state>` — one of `Planned | Active | Completed | Blocked | Revised | All`. Default: omit `Completed` (show Planned + Active + Blocked + Revised).
   - `--iteration <name>` — filter to items whose `Iteration` field matches the given iteration name (case-insensitive). Default: no iteration filter.

3. **Fetch items**:
   ```bash
   gh project item-list <project-num> --owner <owner> --format json --limit 100 \
     | jq '.items[] | select(.fieldValues[]? | (.name=="Type" and .text=="Directive"))'
   ```
   Apply the Status / Iteration filters from step 2 with additional `jq` selectors against `fieldValues`.

4. **Output as a table** (markdown-style, sorted by Priority then Status):

   | ID | Status | Priority | Title (Objective) | Parent Goal | Confidence | Iteration |
   |----|--------|----------|-------------------|-------------|------------|-----------|
   | … | Planned | P0 | <objective ≤60 chars> | Goal-#N or "(none)" | 75 | <iter name> |

   - `ID` is either the Project Item ID (for `Status=Planned` Draft Items) or the GitHub Issue # (for activated Directives — `Status=Active|Completed|Blocked|Revised`).
   - If the list is empty after filters, print: `No Directives match the filter (status=<state> iteration=<name>).`

5. **No audit emission** — this is a read-only query.

## Operating mode

Same output in `attended` and `unattended` modes.

## Examples

```
/list-directives                          # Planned + Active + Blocked + Revised (default)
/list-directives --status Active          # Active only
/list-directives --status All             # Everything including Completed
/list-directives --iteration "2026-Q2"    # Items in the named iteration
```

## Forbidden

- Mutating any field. This is read-only.
- Hiding `Type=Directive` items that match the filter — the user explicitly asked for the dir-mode view.
