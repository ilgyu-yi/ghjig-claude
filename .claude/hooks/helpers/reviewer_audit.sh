# shellcheck shell=bash
# helpers/reviewer_audit.sh — reviewer-reject audit emission (#361, Directive
# #356 signal 3). Sourced by the reviewer-invoking skill flows (/file-issue,
# /work-on, /activate, /complete-directive) via `safe_source`; on miss the skill
# fails-open (the reviewer verdict still gates — only this observability trail
# is best-effort). Assumes `audit_log` (hookrt.sh) is already in scope.
#
# Public:
#   reviewer_reject_audit <category> <reason_class> <issue_no>
#     Emit one categorized reject record for a non-pass reviewer verdict:
#       audit_log warn <category> reject "class=<reason_class> issue=#<issue_no>"
#     <category>     — the reviewer's audit category: issue-review | plan-review
#                      | activation (the latter for /activate + /complete-directive).
#     <reason_class> — one of the documented vocabulary (SPEC §6.1): schema-incomplete
#                      | unverifiable-ac | scope-bleed | mission-misfit | conflict
#                      | evidence-insufficient. The skill maps the reviewer's
#                      free-text reason to the nearest token.
#     <issue_no>     — the Issue/PR number under review (digits; bare, no '#').
#   The promotion-candidate report (signal 4, sibling Execution Issue) aggregates
#   these by <category> × <reason_class>.

reviewer_reject_audit() {
  local category="$1" reason_class="$2" issue_no="$3"
  # audit_log must be in scope (sourced from hookrt.sh by the caller). If it is
  # not, fail-open silently — the trail is best-effort, never the gate.
  command -v audit_log >/dev/null 2>&1 || return 0
  audit_log warn "$category" reject "class=${reason_class} issue=#${issue_no}"
}
