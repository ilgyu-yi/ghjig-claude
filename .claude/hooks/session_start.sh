#!/usr/bin/env bash
set -uo pipefail

# The inject-consistency banner was removed in #318 (Directive #311). Post-#312 a
# plain `claude` in an injected target (env unset + settings.local.json symlink)
# is the NORMAL working state — hooks self-locate via the binding symlink and
# export GHJIG_ROOT below — so the old banner only false-fired. The residual
# genuine no-op (binding symlink missing/broken) is structurally undetectable
# here: this hook is itself invoked through that binding
# (${CLAUDE_PROJECT_DIR}/.claude/ghjig-root/...), so a broken binding means
# this script never runs. See SPEC §6.5(c). The hookrt-missing banner below stays.

# Capture the AMBIENT root before the export below overwrites it — the #537
# banner arms compare it against the self-located root.
_ambient_ghjig_root="${GHJIG_ROOT:-}"
SHELL_ROOT="${GHJIG_ROOT_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
[ -n "$SHELL_ROOT" ] && [ -d "$SHELL_ROOT/.claude/hooks/helpers" ] || exit 0
# Export the resolved root (#312, #537) so helpers that reference $GHJIG_ROOT
# resolve with no global env. Internal/exported-only: the ambient env is never
# consulted here; GHJIG_ROOT_OVERRIDE is a test-only seam (SPEC §3.2.1).
export GHJIG_ROOT="$SHELL_ROOT"

# #537 shell-root env banners (SPEC §6.5(c)) — the resolution above never
# consults the ambient env, so both states below are functionally ignored;
# these once-per-session arms (same mkdir-stamp debounce family as the
# hookrt / registry-zeroed banners) keep that ignore observable, not silent.
# Arm (a): a lingering legacy export, or an ambient GHJIG_ROOT that DISAGREES
# with the self-located root, is dead configuration — name the retirement and
# the fix. (A matching ambient GHJIG_ROOT is the normal parent-export channel
# — scripts/bin/ghjig — and stays silent.)
if [ -n "${GHJIG_SHELL_ROOT:-}" ] \
   || { [ -n "$_ambient_ghjig_root" ] && [ "$_ambient_ghjig_root" != "$SHELL_ROOT" ]; }; then
  _envret_stamp="${TMPDIR:-/tmp}/ghjig-banner-envretired.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_envret_stamp" ] && mkdir "$_envret_stamp" 2>/dev/null; then
    printf '[GHJig-Claude] WARN GHJIG_SHELL_ROOT retired (#537): the ambient shell-root env is IGNORED — hooks self-locate via BASH_SOURCE and export GHJIG_ROOT internally. Fix: unset the stale export (legacy var or mismatched GHJIG_ROOT) from your shell profile.\n' >&2
  fi
fi
# Arm (b): an active GHJIG_ROOT_OVERRIDE redirects which tree the hooks load —
# a test-only seam that must never run silently in a live session.
if [ -n "${GHJIG_ROOT_OVERRIDE:-}" ]; then
  _envseam_stamp="${TMPDIR:-/tmp}/ghjig-banner-envseam.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_envseam_stamp" ] && mkdir "$_envseam_stamp" 2>/dev/null; then
    printf '[GHJig-Claude] NOTE GHJIG_ROOT_OVERRIDE: test-only seam active; hooks loading from %s (SPEC §3.2.1)\n' "$SHELL_ROOT" >&2
  fi
fi

# Primitive bootstrap of hookrt.sh (audit_log + safe_source). SPEC §6.1.
hookrt="$SHELL_ROOT/.claude/hooks/hookrt.sh"
if [ ! -f "$hookrt" ]; then
  # Per-invocation diagnostic floor (stable contract for log scrapers).
  printf '[GHJig-Claude] WARN hookrt-missing: %s not loaded — hook exiting\n' "$hookrt" >&2
  # Once-per-session actionable banner (SPEC §6.5(c)). Same primitive-inline-
  # printf + mkdir-stamp debounce pattern as the inject-consistency banner.
  # Distinct stamp suffix `-hookrt` avoids collision. If mkdir fails (hostile
  # $TMPDIR / low-disk), the banner is suppressed; the per-fire WARN above is
  # the diagnostic floor that survives that failure mode.
  _hookrt_stamp="${TMPDIR:-/tmp}/ghjig-banner-hookrt.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_hookrt_stamp" ] && mkdir "$_hookrt_stamp" 2>/dev/null; then
    printf '[GHJig-Claude] WARN hookrt-missing: hook enforcement OFF until restored. Fix: `git -C %s status` to inspect tree state, then `git -C %s checkout -- .claude/hooks/hookrt.sh` to restore.\n' \
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

# Registry-zeroed detector (#502 / Directive #498). The per-project scope-guard
# registry going EMPTY — `: > registry.txt`, `truncate`, or a delete-then-touch —
# silently turns ALL enforcement off: the global `in_scope` gate fails open on an
# empty/absent registry (by design, SPEC §3.2.2 / §6.1 / §773). That fail-open is
# DELIBERATELY UNCHANGED here (no SPEC §1.4 flip — the empty-registry transparency
# is the guardrail-not-sandbox posture); this only makes the zeroed STATE
# OBSERVABLE rather than traceless (#502 AC5). A present-but-EMPTY registry is the
# distinguishable "armed-then-disarmed" signal; an ABSENT registry is the normal
# pre-registration / unregistered-cwd transparent case and does NOT fire. Loud
# once-per-session banner (debounced) + audit warn, mirroring the hookrt banner.
# (The binding-symlink-repoint disable stays a documented residual — SPEC §6.5(c)
#  — because this detector is itself reached THROUGH the binding.)
_ce_reg=$(ghjig_registry_file 2>/dev/null || true)
# Mirror the reader's back-compat resolution order (cwd_guard.sh:12,62): if the
# per-project registry is ABSENT, in_scope/path_in_scope fall back to the legacy
# shared registry — so an empty legacy-shared file ALSO silently disables
# enforcement. Resolve the SAME file the reader would, else that state stays a
# silent blind spot (banner mute while enforcement is OFF). Absent-both remains
# the transparent normal case (the [ -f ] guard below simply won't fire).
[ -f "${_ce_reg:-}" ] || _ce_reg="${GHJIG_ROOT:-}/.claude/state/registry.txt"
if [ -n "$_ce_reg" ] && [ -f "$_ce_reg" ] && ! grep -q '[^[:space:]]' "$_ce_reg" 2>/dev/null; then
  # Banner FIRST (the user-visible AC5 signal), debounced once per session.
  _reg_stamp="${TMPDIR:-/tmp}/ghjig-banner-regzero.${CLAUDE_SESSION_ID:-$PPID}"
  if [ ! -d "$_reg_stamp" ] && mkdir "$_reg_stamp" 2>/dev/null; then
    printf '[GHJig-Claude] WARN registry-zeroed: scope-guard registry %s is EMPTY — hook enforcement is OFF (fails open on an empty registry). Fix: re-register this project (`scripts/register.sh`) or `git`-restore the registry, then restart the session.\n' "$_ce_reg" >&2
  fi
  # Audit record in a SUBSHELL so any audit_log misbehavior (e.g. a `set -u`
  # abort on an unusual env) cannot kill this hook before/after the banner.
  ( audit_log warn registry-zeroed notice "scope-guard registry present-but-empty → enforcement OFF (in_scope fails open): $_ce_reg" ) >/dev/null 2>&1 || true
fi

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
      printf '[GHJig-Claude] shell repo is %s commit(s) behind origin. consider pulling.\n' "$behind"
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
  esd=$(ghjig_state_dir 2>/dev/null || true)
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

  local nc pc ce sd hits=0 log parks=0 sd_count=0
  if [ -n "$timeout_bin" ]; then
    nc=$("$timeout_bin" "$secs" bash "$run/narrowing_candidates.sh" 2>/dev/null || true)
    pc=$("$timeout_bin" "$secs" bash "$run/promotion_candidates.sh" 2>/dev/null || true)
    # Ceremony + spec-drift readers mine git history of the project repo (§6.5(d),
    # #401/#466); the timeout + || true envelope degrades a non-repo cwd / missing
    # base to silence. Both default to $CLAUDE_PROJECT_DIR (no path arg), like the trio.
    ce=$("$timeout_bin" "$secs" bash "$run/ceremony_candidates.sh" 2>/dev/null || true)
    sd=$("$timeout_bin" "$secs" bash "$run/spec_drift_candidates.sh" 2>/dev/null || true)
  else
    nc=$(bash "$run/narrowing_candidates.sh" 2>/dev/null || true)
    pc=$(bash "$run/promotion_candidates.sh" 2>/dev/null || true)
    ce=$(bash "$run/ceremony_candidates.sh" 2>/dev/null || true)
    sd=$(bash "$run/spec_drift_candidates.sh" 2>/dev/null || true)
  fi
  # Candidate cluster lines are indented and carry " | … =" (escapes=/days=/files=/etc.);
  # the "(none above threshold)"/"no records" sentinels and headers do not.
  printf '%s\n%s\n%s\n%s\n' "$nc" "$pc" "$ce" "$sd" | grep -qE '^[[:space:]]+.+\|.+=' && hits=1
  # Spec-drift candidate count (§6.5(d), #466): each `  <path> | drift-commits=N` line
  # is one drifted path; surfaced in the advisory line below.
  sd_count=$(printf '%s\n' "$sd" | grep -cE 'drift-commits=' 2>/dev/null || true)
  case "$sd_count" in ""|*[!0-9]*) sd_count=0 ;; esac

  # Park-frequency signal — read the same aggregate directly (neither candidate
  # script matches a warn/parked record). SPEC §5.7.1 / §6.5(d).
  log=$(resolve_audit_log "" 2>/dev/null || true)
  if [ -n "$log" ] && [ -s "$log" ]; then
    parks=$(grep -v '^[[:space:]]*$' "$log" \
      | jq -rs '[.[] | select(.category == "unattended-park")] | length' 2>/dev/null || echo 0)
  fi
  case "$parks" in ""|*[!0-9]*) parks=0 ;; esac

  if [ "$hits" -eq 1 ] || [ "$parks" -gt 0 ]; then
    local msg="[GHJig-Claude] friction advisory: accumulated friction detected"
    [ "$parks" -gt 0 ] && msg="$msg (${parks} unattended park record(s))"
    [ "$sd_count" -gt 0 ] && msg="$msg (${sd_count} spec-drift candidate(s))"
    msg="$msg — review via /audit or scripts/narrowing_candidates.sh + scripts/promotion_candidates.sh + scripts/ceremony_candidates.sh + scripts/spec_drift_candidates.sh"
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
printf '[GHJig-Claude] branch: %s\n' "$branch"

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
    printf '[GHJig-Claude] SSOT-nudge: SPEC.md absent — SPEC is the required behavioural SSOT (SPEC §1.3); author it before other work (scaffold: .claude/templates/spec.md).\n'
  elif [ "$_ssot_spec" = ok ]; then
    _ssot_mg='✗'; [ "$_ssot_mission" = ok ] && _ssot_mg='✓'
    printf '[GHJig-Claude] SSOT: MISSION.md %s SPEC.md ✓\n' "$_ssot_mg"
  fi
fi

# 2.6) Local git-hook tier drift arm (SPEC §6.7, #604). Mirror the §6.5(e)
# onboard_checks.sh --dry-run single-sourced-predicate idiom: call the
# installer's OWN --check (no reimplemented `git config --get core.hooksPath`)
# so this arm and the installer can never diverge. When the tier is INERT
# (core.hooksPath unset or ≠ .githooks — a fresh-clone per-clone bootstrap gap),
# emit one advisory naming the installer. Detect-not-silently-pass (§6.5(c)
# silent-no-op hazard); fail-open to silence on any error / non-repo cwd (the
# in-scope + `command -v git` guards above already hold here).
_ghook_inst="$SHELL_ROOT/scripts/install_git_hooks.sh"
if [ -f "$_ghook_inst" ] && ! "$_ghook_inst" --check >/dev/null 2>&1; then
  printf '[GHJig-Claude] git-hook tier INERT — the committed .githooks/ local enforcement tier is not activated for this clone. Activate (repo-local, reversible): scripts/install_git_hooks.sh (SPEC §6.7).\n'
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
