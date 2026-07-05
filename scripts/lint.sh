#!/usr/bin/env bash
# scripts/lint.sh — pinned, reproducible shellcheck lint runner (#545).
#
# One script that BOTH CI (the `syntax` job) and a developer run, so
# "clean locally" and "clean in CI" are one predicate by construction
# (§7.4/§18.6 local-pre-image-of-remote-gate). It:
#   1. resolves a version-PINNED shellcheck (SHA256-verified, fail-closed),
#   2. enumerates the shell sources (bash 3.2-safe, NUL-delimited),
#   3. runs `bash -n` + shellcheck PER FILE (bounds peak RSS at the single
#      largest file — a combined pass OOM-killed the ubuntu runner, #539),
#   4. on Linux, flags peak RSS via /usr/bin/time -v as a legible
#      approaching-the-cliff canary (never a spurious red).
# See SPEC §11.
set -euo pipefail

# ---------------------------------------------------------------------------
# 1. Version pin + per-platform SHA256 table (floor >=0.10.0 — first release
#    shipping a darwin.aarch64 asset, which macos-latest runners need).
#    Checksums are over the release .tar.xz, captured from a trusted download,
#    so verification needs no network of its own.
# ---------------------------------------------------------------------------
GHJIG_SHELLCHECK_VERSION="0.11.0"

_sha256_for_platform() {
  case "$1" in
    linux.x86_64)   echo "8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198" ;;
    linux.aarch64)  echo "12b331c1d2db6b9eb13cfca64306b1b157a86eb69db83023e261eaa7e7c14588" ;;
    darwin.x86_64)  echo "3c89db4edcab7cf1c27bff178882e0f6f27f7afdf54e859fa041fca10febe4c6" ;;
    darwin.aarch64) echo "56affdd8de5527894dca6dc3d7e0a99a873b0f004d7aabc30ae407d3f48b0a79" ;;
    *) return 1 ;;
  esac
}

# SHA256 over a file, portable across Linux (sha256sum) and macOS (shasum).
_sha256_of_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "ERROR: neither sha256sum nor shasum found; cannot verify shellcheck" >&2
    exit 1
  fi
}

# host OS/arch -> canonical "<os>.<arch>" matching the release asset naming.
_detect_platform() {
  local os arch
  case "$(uname -s)" in
    Linux)  os="linux" ;;
    Darwin) os="darwin" ;;
    *) echo "ERROR: unsupported OS $(uname -s)" >&2; exit 1 ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)  arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) echo "ERROR: unsupported arch $(uname -m)" >&2; exit 1 ;;
  esac
  echo "${os}.${arch}"
}

# ---------------------------------------------------------------------------
# 2. Resolve the pinned binary: cache-hit -> reuse; else download + verify +
#    extract + cache. FAIL-CLOSED: on download failure or SHA256 mismatch we
#    print a legible error and exit 1 — an unverified binary is NEVER run.
#    Echoes the resolved binary path on stdout (everything else -> stderr).
# ---------------------------------------------------------------------------
ensure_pinned_shellcheck() {
  local platform os arch expected_sha cache_dir bin url tarball actual_sha extract_dir
  platform="$(_detect_platform)"
  os="${platform%.*}"
  arch="${platform#*.}"

  expected_sha="$(_sha256_for_platform "$platform")" || {
    echo "ERROR: no pinned SHA256 for platform '$platform' (shellcheck v${GHJIG_SHELLCHECK_VERSION})" >&2
    exit 1
  }

  # Gitignored, registry-free cache (never the scope-guard registry surface).
  cache_dir="${GHJIG_SHELLCHECK_CACHE:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/ghjig-shellcheck}/v${GHJIG_SHELLCHECK_VERSION}/${os}-${arch}"
  bin="$cache_dir/shellcheck"

  if [ -x "$bin" ]; then
    echo "$bin"
    return 0
  fi

  mkdir -p "$cache_dir"
  url="https://github.com/koalaman/shellcheck/releases/download/v${GHJIG_SHELLCHECK_VERSION}/shellcheck-v${GHJIG_SHELLCHECK_VERSION}.${platform}.tar.xz"
  tarball="$(mktemp)"

  echo "→ fetching pinned shellcheck v${GHJIG_SHELLCHECK_VERSION} (${platform})" >&2
  if ! curl --retry 3 --retry-all-errors -sSL -o "$tarball" "$url"; then
    echo "ERROR: failed to download shellcheck from $url" >&2
    rm -f "$tarball"
    exit 1
  fi

  actual_sha="$(_sha256_of_file "$tarball")"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "ERROR: SHA256 mismatch for shellcheck v${GHJIG_SHELLCHECK_VERSION} (${platform})" >&2
    echo "  expected: $expected_sha" >&2
    echo "  actual:   $actual_sha" >&2
    echo "  refusing to run an unverified binary" >&2
    rm -f "$tarball"
    exit 1
  fi

  extract_dir="$(mktemp -d)"
  if ! tar -xJf "$tarball" -C "$extract_dir"; then
    echo "ERROR: failed to extract shellcheck tarball" >&2
    rm -f "$tarball"
    rm -rf "$extract_dir"
    exit 1
  fi

  if [ ! -f "$extract_dir/shellcheck-v${GHJIG_SHELLCHECK_VERSION}/shellcheck" ]; then
    echo "ERROR: extracted tarball missing shellcheck binary" >&2
    rm -f "$tarball"
    rm -rf "$extract_dir"
    exit 1
  fi

  mv "$extract_dir/shellcheck-v${GHJIG_SHELLCHECK_VERSION}/shellcheck" "$bin"
  chmod +x "$bin"
  rm -f "$tarball"
  rm -rf "$extract_dir"
  echo "$bin"
}

# ---------------------------------------------------------------------------
# 3+4. Enumerate + lint per file, with the Linux peak-RSS flag.
# ---------------------------------------------------------------------------
main() {
  local shellcheck_bin f files use_time time_bin max_rss_kb cap_kb
  shellcheck_bin="$(ensure_pinned_shellcheck)"
  echo "→ using shellcheck: $shellcheck_bin" >&2
  "$shellcheck_bin" --version | head -3 >&2 || true

  # Enumerate via find — portable across bash 3.2 (macOS system bash) and
  # bash 4+ (Linux). NUL-delimited to survive any path-with-spaces.
  files=()
  if [ -f bin/ghjig ]; then
    files+=(bin/ghjig)
  fi
  while IFS= read -r -d '' f; do
    files+=("$f")
  done < <(find scripts .claude/hooks -type f -name '*.sh' -print0)

  if [ "${#files[@]}" -eq 0 ]; then
    echo "ERROR: no shell files found — repo layout changed?" >&2
    exit 1
  fi

  # Linux peak-RSS flag: GNU `/usr/bin/time -v` reports "Maximum resident set
  # size (kbytes)" per invocation. macOS BSD time has no -v, so the split
  # alone is the guard there. Probe for a working GNU time before relying on it.
  time_bin="/usr/bin/time"
  use_time=0
  if [ "$(uname -s)" = "Linux" ] && [ -x "$time_bin" ] && "$time_bin" -v true >/dev/null 2>&1; then
    use_time=1
  fi

  # Memory cap — a LEGIBLE flag, not a hard `ulimit -v` (which caps virtual
  # address space, not RSS, and false-reds legitimate Haskell/GHC runs).
  #   - The dominant file is the ~14.3k-line scripts/test/smoke.sh; measured
  #     per-file peak ~12.3 GB RSS on darwin.aarch64 (cross-platform upper
  #     reference — the flag itself only runs on Linux).
  #   - The pre-#539 COMBINED pass held every file's AST at once and peaked
  #     ~18 GB, OOM-killing the ~16 GB ubuntu runner as an illegible
  #     "runner received a shutdown signal".
  #   - Cap = 14 GiB (14680064 KB), ~87.5% of the 16 GB ubuntu-latest runner:
  #     above the observed ~12.3 GB legitimate per-file peak (so a real run
  #     NEVER trips it) yet below the ~18 GB combined-pass regression (so the
  #     split being removed, or a file ballooning, trips it with a named cap).
  cap_kb=14680064
  max_rss_kb=0

  local timelog rss
  for f in "${files[@]}"; do
    echo "→ bash -n $f" >&2
    bash -n "$f"
    echo "→ shellcheck $f" >&2
    if [ "$use_time" -eq 1 ]; then
      timelog="$(mktemp)"
      if ! "$time_bin" -v "$shellcheck_bin" --severity=warning --shell=bash "$f" 2>"$timelog"; then
        cat "$timelog" >&2
        rm -f "$timelog"
        exit 1
      fi
      rss="$(awk '/Maximum resident set size/ {print $NF}' "$timelog")"
      rm -f "$timelog"
      if [ -n "${rss:-}" ] && [ "$rss" -gt "$max_rss_kb" ]; then
        max_rss_kb="$rss"
      fi
    else
      "$shellcheck_bin" --severity=warning --shell=bash "$f"
    fi
  done

  if [ "$use_time" -eq 1 ]; then
    echo "→ peak shellcheck RSS: ${max_rss_kb} KB (budget ${cap_kb} KB)" >&2
    # A LEGIBLE FLAG, not a gate: emit a loud warning but do NOT fail. The
    # legitimate per-file baseline (~12.3 GB on the dominant smoke.sh) sits
    # close to any runner-safe budget, so a hard exit here would risk a
    # false-red on a clean run — the exact flaky, non-reproducible signal this
    # work exists to kill (§11, #545). The combined-pass regression is already
    # gated by the smoke §138b structural lock (and would OOM the runner before
    # /usr/bin/time could even report), so this check's job is to SURFACE a
    # single file creeping toward the cliff, not to block CI on it.
    if [ "$max_rss_kb" -gt "$cap_kb" ]; then
      echo "WARNING: peak shellcheck RSS ${max_rss_kb} KB exceeded the ${cap_kb} KB budget." >&2
      echo "  A per-file lint should stay well under this — has the per-file" >&2
      echo "  split regressed to a combined pass, or has a source file ballooned?" >&2
      echo "  (Non-fatal flag — CI is not failed on this; act before it OOMs the runner.)" >&2
    fi
  fi

  echo "lint OK: ${#files[@]} files clean (shellcheck v${GHJIG_SHELLCHECK_VERSION})" >&2
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
