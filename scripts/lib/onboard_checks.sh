#!/usr/bin/env bash
# scripts/lib/onboard_checks.sh — the single shared implementation of the
# mechanical onboard pre-flight checks (Execution #456, Directive #454).
#
# It is the ONE source for these present/absent facts, consumed by both the
# `/onboard` slash command (Claude renders the lines as ✓/✗) and the forthcoming
# `scripts/setup.sh` single entry — so neither carries a divergent copy of the
# check logic (SPEC §9). The judgment half (SSOT *drafting*, SPEC-first prompting,
# `.github/` install proposals) stays in `/onboard` prose: those need authoring
# judgment and the MISSION scaffold-not-author boundary a fact-reporter must not encode.
#
# Run from the target repo's cwd. Emits ONE line per check on stdout:
#
#     <check-name>  <status>  <one-line detail>
#
# where <status> is the stable token `ok` or `fail` (NOT a glyph — renderers map it
# to their own presentation, keeping this script presentation-neutral). Check names:
# upstream, permission, ssot:MISSION.md, ssot:SPEC.md, branch-protect, ci,
# toc-format, docs-pointer.
#
# It REPORTS facts and never gates: every invocation exits 0, even when a `gh`
# probe errors (a non-admin `gh api .../protection` 404/403 is reported as
# `branch-protect fail`, not a crash). `gh` is reached via $PATH so it is stubbable.
#
# --dry-run / no-gh: when --dry-run is passed or `gh` is unavailable, the three
# gh-dependent checks (upstream, permission, branch-protect) emit `fail` with a
# "not queried" detail — the structural output stays complete (all six lines) for
# no-auth / smoke contexts, and `fail` correctly reads as "not confirmed OK".

set -uo pipefail

# Self-locate the sibling build_toc (scripts/lib/ → scripts/build_toc.sh) for the
# gh-free toc-format check.
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BUILD_TOC="$LIB_DIR/../build_toc.sh"

DRY_RUN=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    *) printf 'onboard_checks: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

# emit <check> <status> <detail…>
emit() { printf '%s %s %s\n' "$1" "$2" "$3"; }

# Is the live gh path usable? (present on PATH and not suppressed by --dry-run)
gh_usable() { [ -z "$DRY_RUN" ] && command -v gh >/dev/null 2>&1; }

# ---- upstream / fork ----
if gh_usable; then
  isfork=$(gh repo view --json isFork --jq .isFork 2>/dev/null)
  if [ "$isfork" = false ]; then
    emit upstream ok "not a fork"
  elif [ "$isfork" = true ]; then
    emit upstream fail "this repo is a fork — the shell is upstream-only"
  else
    emit upstream fail "could not determine fork status (gh)"
  fi
else
  emit upstream fail "not queried (--dry-run or gh unavailable)"
fi

# ---- push permission ----
if gh_usable; then
  perm=$(gh repo view --json viewerPermission --jq .viewerPermission 2>/dev/null)
  case "$perm" in
    ADMIN|MAINTAIN|WRITE) emit permission ok "push permission: $perm" ;;
    "")                   emit permission fail "could not determine push permission (gh)" ;;
    *)                    emit permission fail "push permission missing (have: $perm)" ;;
  esac
else
  emit permission fail "not queried (--dry-run or gh unavailable)"
fi

# ---- SSOT presence (the frequently-consulted MISSION+SPEC pair, SPEC §1.3) ----
# Presence only — mechanical. Drafting / SPEC-first prompting is /onboard's prose job.
for ssot in MISSION.md SPEC.md; do
  if [ -f "$ssot" ]; then
    emit "ssot:$ssot" ok "present"
  else
    emit "ssot:$ssot" fail "absent — required behavioural SSOT (SPEC §1.3)"
  fi
done

# ---- branch protection on the default branch ----
# `gh api` does NO repo host inference — a host-LESS call resolves gh's DEFAULT
# host (github.com), so on a GHES target the protection probe hits the wrong host
# and reports a false `fail`. Derive the repo host from gh's normalized url (the
# #610 chop, folding `url` into the same `gh repo view` read) and pin it with
# `--hostname`. Fail CLOSED on an unusable host — NEVER a host-less fallback that
# could probe github.com and mis-report (#614).
if gh_usable; then
  default_branch=$(gh repo view --json defaultBranchRef,url --jq .defaultBranchRef.name 2>/dev/null)
  [ -z "$default_branch" ] && default_branch=main
  repo_url=$(gh repo view --json defaultBranchRef,url --jq .url 2>/dev/null)
  h=${repo_url#*://}; h=${h#*@}; h=${h%%/*}
  case "$h" in
    ''|*[!A-Za-z0-9.:-]*)
      emit branch-protect fail "could not resolve repo host from url (${repo_url}) — authenticate gh to that host" ;;
    *)
      if gh api "repos/{owner}/{repo}/branches/${default_branch}/protection" --hostname "$h" >/dev/null 2>&1; then
        emit branch-protect ok "protected (${default_branch})"
      else
        emit branch-protect fail "absent or unreadable on ${default_branch}@${h} (may need admin)"
      fi ;;
  esac
else
  emit branch-protect fail "not queried (--dry-run or gh unavailable)"
fi

# ---- CI presence ----
if [ -d .github/workflows ] && [ -n "$(ls -A .github/workflows 2>/dev/null)" ]; then
  emit ci ok "present (.github/workflows/)"
else
  emit ci fail "no workflows under .github/workflows/"
fi

# ---- SPEC ToC FORMAT (gh-free — build_toc.sh --check is filesystem-only) ----
# FORMAT, not freshness: a stale-but-markered ToC (--check 1) is `ok` here because
# freshness is CI's job (check-toc.yml) and the format is sound. `toc_rc=0` pre-init
# is load-bearing under `set -u` (an unset read would abort → break exit-0), and the
# `[ -f SPEC.md ]` guard means build_toc is never called on an absent SPEC (→ *→ok).
toc_rc=0
if [ -f SPEC.md ] && [ -x "$BUILD_TOC" ]; then
  bash "$BUILD_TOC" --check --spec SPEC.md >/dev/null 2>&1 || toc_rc=$?
fi
case "$toc_rc" in
  3) emit toc-format fail "marker-less/anchor-link ToC — run build_toc.sh --migrate (only if SPEC.md already uses numbered '## N.' headings + a '## Table of contents' block; else number the headings or add the <!-- TOC START -->/<!-- TOC END --> markers by hand)" ;;
  4) emit toc-format fail "corrupt TOC markers (START without END) — repair the markers" ;;
  *) emit toc-format ok "marker line-number ToC (or SPEC.md absent / no ToC to convert)" ;;
esac

# ---- docs/*.md thin-pointer norm (§91 parity, SPEC §9) ----
# Each docs/*.md must lead (first two non-empty lines) with a SPEC reference. The
# for-glob loop with `[ -f "$d" ] || continue` skips the literal glob string when no
# docs/*.md exists → dp_fail empty → ok. `dp_fail=""` pre-init is safe under `set -u`.
dp_fail=""
for d in docs/*.md; do
  [ -f "$d" ] || continue
  lead=$(awk 'NF{n++; print; if(n==2) exit}' "$d")
  case "$lead" in *SPEC*) : ;; *) dp_fail="$dp_fail ${d##*/}" ;; esac
done
if [ -n "$dp_fail" ]; then
  emit docs-pointer fail "not leading with a SPEC reference:$dp_fail (thin-pointer norm, SPEC §9) — lead each with a 'Full details in SPEC §…' reference"
else
  emit docs-pointer ok "every docs/*.md leads with a SPEC reference (or none present)"
fi

exit 0
