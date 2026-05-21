# shellcheck shell=bash
# helpers/detect_stack.sh — language / test / formatter detection. Source from hooks.
# Supported stacks: node, python, go, rust, ruby, godot. See SPEC.md §6.6 for the
# sentinel files, test/lint/format commands, and stack-specific notes.

detect_stack() {
  if [ -f package.json ]; then echo node; return; fi
  if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then echo python; return; fi
  if [ -f go.mod ]; then echo go; return; fi
  if [ -f Cargo.toml ]; then echo rust; return; fi
  if [ -f Gemfile ]; then echo ruby; return; fi
  if [ -f project.godot ]; then echo godot; return; fi
  echo unknown
}

detect_test_cmd() {
  case "$(detect_stack)" in
    node)
      if [ -f package.json ] && grep -q '"test"' package.json 2>/dev/null; then echo "npm test"; fi ;;
    python)
      command -v pytest >/dev/null 2>&1 && echo "pytest" ;;
    go) echo "go test ./..." ;;
    rust) echo "cargo test" ;;
    ruby) command -v bundle >/dev/null && echo "bundle exec rspec" ;;
    godot)
      # GUT (Godot Unit Test) addon present → run its CLI; otherwise parse-only boot.
      if [ -f addons/gut/gut_cmdln.gd ]; then
        echo "godot --headless --path . -s res://addons/gut/gut_cmdln.gd -gexit"
      else
        echo "godot --headless --path . --quit-after 1"
      fi
      ;;
  esac
}

detect_lint_cmd() {
  case "$(detect_stack)" in
    node) command -v npx >/dev/null && [ -f package.json ] && grep -q '"lint"' package.json 2>/dev/null && echo "npm run lint" ;;
    python) command -v ruff >/dev/null && echo "ruff check ." ;;
    go) echo "go vet ./..." ;;
    rust) echo "cargo check" ;;
    godot) command -v gdlint >/dev/null 2>&1 && echo "gdlint ." ;;
  esac
}

_lint_timeout_warned=0

# run_bounded_lint <cmd>
#   Runs <cmd> via timeout(1) (or gtimeout(1) on macOS) bounded by
#   CLAUDE_ENG_LINT_TIMEOUT seconds (default 30). Returns the command's
#   exit code, or the timeout exit (typically 124) when the bound fires.
#   If neither timeout binary is on PATH, emits an audit_log warn once
#   per process and falls back to unbounded execution — better to surface
#   the missing dep than to silently disable enforcement or hang.
run_bounded_lint() {
  local cmd="$1"
  local secs="${CLAUDE_ENG_LINT_TIMEOUT:-30}"
  local timeout_bin=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_bin=timeout
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_bin=gtimeout
  fi
  if [ -z "$timeout_bin" ]; then
    if [ "${_lint_timeout_warned:-0}" = "0" ] && command -v audit_log >/dev/null 2>&1; then
      audit_log warn lint-timeout-absent notice "timeout(1)/gtimeout(1) not on PATH; lint runs unbounded"
      _lint_timeout_warned=1
    fi
    eval "$cmd"
    return $?
  fi
  "$timeout_bin" "$secs" sh -c "$cmd"
}

detect_format_cmd() {
  local file="$1"
  # Shell-quote the file path so the caller's `eval` cannot execute injected
  # metacharacters from the filename. printf '%q' is a bash builtin and is
  # safe to use here because all hook helpers run under #!/usr/bin/env bash.
  local qfile
  qfile=$(printf '%q' "$file")
  case "$file" in
    *.py) command -v ruff >/dev/null && { echo "ruff format $qfile"; return; }
          command -v black >/dev/null && echo "black $qfile" ;;
    *.js|*.jsx|*.ts|*.tsx|*.json|*.md|*.yml|*.yaml)
          command -v prettier >/dev/null && echo "prettier --write $qfile" ;;
    *.go) command -v gofmt >/dev/null && echo "gofmt -w $qfile" ;;
    *.rs) command -v rustfmt >/dev/null && echo "rustfmt $qfile" ;;
    *.gd) command -v gdformat >/dev/null 2>&1 && echo "gdformat $qfile" ;;
  esac
}
