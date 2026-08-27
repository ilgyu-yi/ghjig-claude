# shellcheck shell=bash
# shellcheck source=_preamble.sh
# Sourced by scripts/test/smoke.sh after 73-rounds.sh (#728). The guarded
# source below never runs at runtime (the orchestrator already sourced the
# preamble); it only lets shellcheck resolve the shared globals.
if false; then . "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"; fi

# ---------- §186: the claim-ordering step reaches every authoring carrier (#728) ----------
# Every surface that authors a durable body carries one advisory "Claim
# ordering" step (SPEC §1.11 L2/L5, instrument: scripts/ghjig_evidence.sh). §186a locks that wiring as a GENERATED-OUTPUT COMPARISON: the
# required carrier set is DERIVED at run time by the #705 predicate over the
# live command/agent files — never hand-listed — and each derived-and-not-
# excluded carrier must contain the instrument's filename. The only fixed
# string asserted anywhere in this section is `ghjig_evidence.sh` — a script
# path (itself an L2 pointer), not doctrine prose.
#
# What this section locks — and, per #728 AC5, what it deliberately does NOT:
#   * PRESENCE only. No arm observes claims-per-body — no such instrument
#     exists (scripts/accretion_candidates.sh does not exist, and per Directive
#     #637 item 4's spec it would scan SSOT paths, not issue/PR bodies). The
#     change's success criterion — fewer descriptive claims per durable body,
#     never more rendered blocks — is a review-time judgment, not a smoke
#     assertion.
#   * The ordering WORDING (delete → pointer → render-last) is process-guarded:
#     SPEC §1.11 L3 bans new phrase-pinning content locks, which is why no arm
#     here asserts the step's text.
# §186b guards the arm against its own staleness: each hand-carried exclusion
# must still be DERIVABLE (else its reason is dead text), and the one hand-
# pinned carrier must still be UNDERIVABLE (else the reason for hand-pinning
# it is false).

S186_CMD_DIR="$SHELL_ROOT/.claude/commands"
S186_AGT_DIR="$SHELL_ROOT/.claude/agents"

# s186_writes_body <file> — the #705 predicate: after joining backslash-
# continued lines, some logical line runs a gh body write. The verbs are
# PINNED to create|edit: a comment is not one of the durable authored bodies
# the step targets, and admitting comment verbs breaks the derived
# arithmetic (every comment-writing surface would qualify).
s186_writes_body() {
  s186_wb_j=$(sed -e :a -e '/\\$/N; s/\\\n//; ta' "$1" 2>/dev/null)
  for s186_wb_v in "issue create" "issue edit" "pr create" "pr edit"; do
    printf '%s\n' "$s186_wb_j" | grep -E "gh $s186_wb_v" | grep -qE -- '--body(-file)?' \
      && return 0
  done
  return 1
}
# s186_in <name> <space-separated-set>
s186_in() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# DERIVED — the predicate's rows over both carrier globs, basenames. The
# count-guard S186_SCANNED keeps an empty glob from greening "all carriers"
# vacuously (smoke.sh anti-vacuity discipline #279).
S186_SCANNED=0
S186_DERIVED=""
for s186_f in "$S186_CMD_DIR"/*.md "$S186_AGT_DIR"/*.md; do
  [ -f "$s186_f" ] || continue
  S186_SCANNED=$((S186_SCANNED + 1))
  s186_writes_body "$s186_f" && S186_DERIVED="$S186_DERIVED $(basename "$s186_f")"
done

# The four derived-but-excluded surfaces, each carried WITH its one-clause
# reason (#728) — §186b reds if any stops being derivable (dead exclusion):
#   activate.md       — refiles a sanitized untrusted draft, not an authored body
#   discuss.md        — deliberately friction-free discussion tier
#   link-directive.md — prepends a marker line to an existing body
#   release.md        — static templated literal body
S186_EXCLUDED="activate.md discuss.md link-directive.md release.md"
# planner.md is HAND-PINNED by name, not derived: the predicate cannot return
# a surface whose Plan output becomes PR-body content WITHOUT a gh call —
# #728 AC1's stated blind spot, not the start of a hand-list. §186b reds if
# planner.md ever becomes derivable (the pin's reason would then be false).
S186_HANDPIN="planner.md"

# REQUIRED = (DERIVED minus the four exclusions) + the hand-pin.
S186_REQUIRED=""
for s186_f in $S186_DERIVED; do
  s186_in "$s186_f" "$S186_EXCLUDED" || S186_REQUIRED="$S186_REQUIRED $s186_f"
done
S186_REQUIRED="$S186_REQUIRED $S186_HANDPIN"

# CARRYING — fixed-string presence of the instrument's filename, same globs.
S186_CARRYING=""
for s186_f in "$S186_CMD_DIR"/*.md "$S186_AGT_DIR"/*.md; do
  [ -f "$s186_f" ] || continue
  grep -qF 'ghjig_evidence.sh' "$s186_f" && S186_CARRYING="$S186_CARRYING $(basename "$s186_f")"
done

s186_der_n=0; for s186_f in $S186_DERIVED;  do s186_der_n=$((s186_der_n + 1)); done
s186_req_n=0; for s186_f in $S186_REQUIRED; do s186_req_n=$((s186_req_n + 1)); done
s186_car_n=0; for s186_f in $S186_CARRYING; do s186_car_n=$((s186_car_n + 1)); done

# §186a (STRUCTURAL LOCK — REQUIRED ⊆ CARRYING): every carrier the predicate
# derives (minus the four reasoned exclusions, plus the hand-pinned planner.md)
# names scripts/ghjig_evidence.sh. Fail-closed: an empty carrier glob or an
# empty derived set reds loudly — never a vacuous green over nothing.
s186_a_miss=""
[ "$S186_SCANNED" -gt 0 ] || s186_a_miss="$s186_a_miss <no-carrier-files-scanned>"
[ "$s186_der_n" -gt 0 ] || s186_a_miss="$s186_a_miss <predicate-derived-nothing>"
for s186_f in $S186_REQUIRED; do
  s186_in "$s186_f" "$S186_CARRYING" || s186_a_miss="$s186_a_miss <missing-carrier:$s186_f>"
done
if [ -z "$s186_a_miss" ]; then
  ok "186a: claim-ordering — derived-set ⊆ carrying-set: all $s186_req_n required carriers ($s186_der_n derived − 4 excluded + 1 hand-pin; $s186_car_n carry the instrument) name ghjig_evidence.sh (#728)"
else
  ng "186a: a required authoring carrier lost (or never gained) the claim-ordering step —$s186_a_miss (#728)"
fi

# §186b (PIN/EXCLUSION STALENESS): each excluded file is still IN the derived
# set — an exclusion the predicate no longer returns is dead text — and
# planner.md is still NOT derivable — a gh body write appearing there would
# falsify the hand-pin's reason (it should then be derived, not pinned).
s186_b_miss=""
[ "$S186_SCANNED" -gt 0 ] || s186_b_miss="$s186_b_miss <no-carrier-files-scanned>"
for s186_f in $S186_EXCLUDED; do
  s186_in "$s186_f" "$S186_DERIVED" \
    || s186_b_miss="$s186_b_miss <dead-exclusion:$s186_f-no-longer-derived>"
done
if s186_in "$S186_HANDPIN" "$S186_DERIVED"; then
  s186_b_miss="$s186_b_miss <hand-pin-falsified:planner.md-now-derivable>"
fi
if [ -z "$s186_b_miss" ]; then
  ok "186b: claim-ordering — the 4 exclusions are all still derivable (live, not dead text) and planner.md is still underivable (the hand-pin's reason holds) (#728)"
else
  ng "186b: an exclusion or the planner.md hand-pin went stale —$s186_b_miss (#728)"
fi
