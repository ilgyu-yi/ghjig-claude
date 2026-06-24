#!/usr/bin/env bash
set -uo pipefail

# The inject-consistency banner was removed in #318 (Directive #311). Post-#312 a
# plain `claude` in an injected target (env unset + settings.local.json symlink)
# is the NORMAL working state — hooks self-locate via the binding symlink and the
# env is back-filled below — so the old banner only false-fired. The residual
# genuine no-op (binding symlink missing/broken) is structurally undetectable
# here: this hook is itself invoked through that binding
# (${CLAUDE_PROJECT_DIR}/.claude/eng-shell-root/...), so a broken binding means
# this script never runs. See SPEC §6.5(c). The hookrt-missing banner below stays.

SHELL_ROOT="${CLAUDE_ENG_SHELL_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0
# Back-fill the env var from self-location (#312) so helpers that reference
# $CLAUDE_ENG_SHELL_ROOT resolve even when launched with no global env.
export CLAUDE_ENG_SHELL_ROOT="$SHELL_ROOT"

# Primitive bootstrap of hookrt.sh (audit_log + safe_source). SPEC §6.1.
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  # Per-invocation diagnostic floor (stable contract for log scrapers).
  printf '[claude-eng-shell] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
  # Once-per-session actionable banner (SPEC §6.5(c)). Same primitive-inline-
  # printf + mkdir-stamp debounce pattern as the inject-consistency banner.
  # Distinct stamp suffix `-hookrt` avoids collision. If mkdir fails (hostile
  # $TMPDIR / low-disk), the banner is suppressed; the per-fire WARN above is
  # the diagnostic floor that survives that failure mode.
  _hookrt_stamp="${TMPDIR:-/tmp}/claude-eng-banner-hookrt.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_hookrt_stamp" ] && mkdir "$_hookrt_stamp" 2>/dev/null; then
    printf '[claude-eng-shell] WARN hookrt-missing: hook enforcement OFF until restored. Fix: `git -C %s status` to inspect tree state, then `git -C %s checkout -- .claude/hooks/hookrt.sh` to restore.\n' \
      "$SHELL_ROOT" "$SHELL_ROOT" >&2
  fi
  exit 0
fi
# shellcheck source=/dev/null
. "$hookrt"

safe_source "$SHELL_ROOT/.claude/hooks/helpers/cwd_guard.sh"     out-of-scope || true
safe_source "$SHELL_ROOT/.claude/hooks/helpers/branch_guard.sh"  branch       || true
# resolve_audit_log — read the SAME aggregate the §6.0 P3 readers consume so the
# §6.5(d) friction advisory below stays consistent with them.
safe_source "$SHELL_ROOT/scripts/lib/audit_log_path.sh"          friction-advisory || true

# 1) Shell self-sync check — always runs regardless of target cwd.
# Gated by .claude/state/last-shell-fetched stamp (SESSION_START_FETCH_TTL
# seconds, default 21600 = 6 h). Fetch is bounded by
# SESSION_START_FETCH_TIMEOUT (default 5 s) via timeout(1)/gtimeout(1).
# See SPEC §6.5(a).
_session_should_fetch() {
  local stamp="$SHELL_ROOT/.claude/state/last-shell-fetched"
  [ -f "$stamp" ] || return 0
  local ttl="${SESSION_START_FETCH_TTL:-21600}"
  local mtime now
  if mtime=$(stat -c %Y "$stamp" 2>/dev/null); then
    :
  elif mtime=$(stat -f %m "$stamp" 2>/dev/null); then
    :
  else
    return 0
  fi
  now=$(date +%s)
  [ "$((now - mtime))" -ge "$ttl" ]
}

_session_run_fetch() {
  local stamp="$SHELL_ROOT/.claude/state/last-shell-fetched"
  local secs="${SESSION_START_FETCH_TIMEOUT:-5}"
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  mkdir -p "$(dirname "$stamp")" 2>/dev/null
  if [ -n "$timeout_bin" ]; then
    (cd "$SHELL_ROOT" && "$timeout_bin" "$secs" git fetch --quiet 2>/dev/null) \
      && touch "$stamp"
  else
    (cd "$SHELL_ROOT" && git fetch --quiet 2>/dev/null) \
      && touch "$stamp"
  fi
}

if command -v git >/dev/null 2>&1; then
  if (cd "$SHELL_ROOT" && git rev-parse --is-inside-work-tree >/dev/null 2>&1); then
    _session_should_fetch && _session_run_fetch
    # `behind` reads local refs (possibly up to TTL stale by design).
    behind=$(cd "$SHELL_ROOT" && git rev-list --count "HEAD..@{u}" 2>/dev/null || echo 0)
    if [ "${behind:-0}" -gt 0 ]; then
      printf '[claude-eng-shell] shell repo is %s commit(s) behind origin. consider pulling.\n' "$behind"
    fi
  fi
fi

# 1.5) Friction-candidate advisory (SPEC §6.5(d), #398, Directive #391).
# Once-per-session, non-blocking, fail-open, TTL-gated trigger that surfaces
# accumulated friction (escape/promotion clusters + unattended-park frequency)
# as ONE advisory line, so the §6.0 P3 / MISSION:16 "deferred positive face" is
# consumed without a human running a script. Runs cwd-independently like the
# sync check (reads the per-project audit aggregate via resolve_audit_log).
_session_friction_advisory() {
  command -v jq >/dev/null 2>&1 || return 0          # readers need jq; fail-open
  command -v resolve_audit_log >/dev/null 2>&1 || return 0

  local esd stamp ttl
  esd=$(eng_state_dir 2>/dev/null || true)
  stamp="${esd:+$esd/last-friction-surfaced}"
  [ -n "$stamp" ] || stamp="$SHELL_ROOT/.claude/state/last-friction-surfaced"
  ttl="${SESSION_START_FRICTION_TTL:-21600}"
  case "$ttl" in ""|*[!0-9]*) ttl=21600 ;; esac

  # TTL gate — skip the compute when the stamp is fresh.
  if [ -f "$stamp" ]; then
    local mtime now
    if mtime=$(stat -c %Y "$stamp" 2>/dev/null) || mtime=$(stat -f %m "$stamp" 2>/dev/null); then
      now=$(date +%s)
      [ "$((now - mtime))" -ge "$ttl" ] || return 0
    fi
  fi

  # Bounded compute (parity with the §6.5(a) fetch: timeout/gtimeout, else unbounded).
  local secs timeout_bin="" run="$SHELL_ROOT/scripts"
  secs="${SESSION_START_FRICTION_TIMEOUT:-3}"
  case "$secs" in ""|*[!0-9]*) secs=3 ;; esac
  if command -v timeout  >/dev/null 2>&1; then timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then timeout_bin=gtimeout; fi

  local nc pc ce hits=0 log parks=0
  if [ -n "$timeout_bin" ]; then
    nc=$("$timeout_bin" "$secs" bash "$run/narrowing_candidates.sh" 2>/dev/null || true)
    pc=$("$timeout_bin" "$secs" bash "$run/promotion_candidates.sh" 2>/dev/null || true)
    # Ceremony reader mines git history of the project repo (§6.5(d), #401); the
    # timeout + || true envelope degrades a non-repo cwd / missing base to silence.
    ce=$("$timeout_bin" "$secs" bash "$run/ceremony_candidates.sh" 2>/dev/null || true)
  else
    nc=$(bash "$run/narrowing_candidates.sh" 2>/dev/null || true)
    pc=$(bash "$run/promotion_candidates.sh" 2>/dev/null || true)
    ce=$(bash "$run/ceremony_candidates.sh" 2>/dev/null || true)
  fi
  # Candidate cluster lines are indented and carry " | … =" (escapes=/days=/files=/etc.);
  # the "(none above threshold)"/"no records" sentinels and headers do not.
  printf '%s\n%s\n%s\n' "$nc" "$pc" "$ce" | grep -qE '^[[:space:]]+.+\|.+=' && hits=1

  # Park-frequency signal — read the same aggregate directly (neither candidate
  # script matches a warn/parked record). SPEC §5.7.1 / §6.5(d).
  log=$(resolve_audit_log "" 2>/dev/null || true)
  if [ -n "$log" ] && [ -s "$log" ]; then
    parks=$(grep -v '^[[:space:]]*$' "$log" \
      | jq -rs '[.[] | select(.category == "unattended-park")] | length' 2>/dev/null || echo 0)
  fi
  case "$parks" in ""|*[!0-9]*) parks=0 ;; esac

  if [ "$hits" -eq 1 ] || [ "$parks" -gt 0 ]; then
    local msg="[claude-eng-shell] friction advisory: accumulated friction detected"
    [ "$parks" -gt 0 ] && msg="$msg (${parks} unattended park record(s))"
    msg="$msg — review via /audit or scripts/narrowing_candidates.sh + scripts/promotion_candidates.sh + scripts/ceremony_candidates.sh"
    printf '%s\n' "$msg"
  fi

  # Touch the stamp only after a successful compute (whether or not a line fired),
  # so the next session within the TTL window skips the recompute.
  mkdir -p "$(dirname "$stamp")" 2>/dev/null || true
  touch "$stamp" 2>/dev/null || true
}
_session_friction_advisory 2>/dev/null || true

# 2) Session restore — only when target cwd is in the registry.
in_scope || exit 0
command -v git >/dev/null 2>&1 || exit 0

branch=$(current_branch)
[ -z "$branch" ] && exit 0
printf '[claude-eng-shell] branch: %s\n' "$branch"

# 2.5) SSOT-presence health line (SPEC §6.5(e), #460, Directive #454).
# Once-per-session (this hook fires once per session), zero-network glance at the
# target's SSOT presence via the shared onboard_checks.sh --dry-run (single source —
# no reimplemented `[ -f SPEC.md ]`; --dry-run short-circuits before any gh call).
# Renders an unobtrusive present line, or a prominent SPEC-first nudge when SPEC.md
# is absent (SPEC is the required behavioural SSOT, §1.3). Fail-open to silence.
_ssot_checks="$SHELL_ROOT/scripts/lib/onboard_checks.sh"
if [ -f "$_ssot_checks" ]; then
  _ssot_out=$("$_ssot_checks" --dry-run 2>/dev/null || true)
  _ssot_spec=$(printf '%s\n' "$_ssot_out" | awk '$1=="ssot:SPEC.md"{print $2; exit}')
  _ssot_mission=$(printf '%s\n' "$_ssot_out" | awk '$1=="ssot:MISSION.md"{print $2; exit}')
  if [ "$_ssot_spec" = fail ]; then
    printf '[claude-eng-shell] SSOT-nudge: SPEC.md absent — SPEC is the required behavioural SSOT (SPEC §1.3); author it before other work (scaffold: .claude/templates/spec.md).\n'
  elif [ "$_ssot_spec" = ok ]; then
    _ssot_mg='✗'; [ "$_ssot_mission" = ok ] && _ssot_mg='✓'
    printf '[claude-eng-shell] SSOT: MISSION.md %s SPEC.md ✓\n' "$_ssot_mg"
  fi
fi

if [ -f MISSION.md ]; then
  printf '[MISSION summary]\n'
  head -n 20 MISSION.md
fi

if command -v gh >/dev/null 2>&1; then
  body=$(gh pr view --json body --jq .body 2>/dev/null || true)
  if [ -n "$body" ]; then
    printf '[current PR body]\n%s\n' "$body" | head -c 8192
  fi
fi

exit 0
