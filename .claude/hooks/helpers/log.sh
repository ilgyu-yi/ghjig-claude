# shellcheck shell=bash
# helpers/log.sh — compatibility shim. `audit_log` and `_audit_json_string`
# moved to .claude/hooks/hookrt.sh in #34. Direct callers (tests, future
# tooling) that source this file by path still get the same symbols.
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../hookrt.sh"
