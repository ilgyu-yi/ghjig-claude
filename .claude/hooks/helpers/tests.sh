# shellcheck shell=bash
# helpers/tests.sh — test runner used by /ship. Source then call run_tests.

run_tests() {
  local cmd
  cmd=$(detect_test_cmd)
  if [ -z "$cmd" ]; then
    echo "No test runner detected (supported: node/python/go/rust/ruby/godot)" >&2
    return 2
  fi
  echo ">> $cmd"
  eval "$cmd"
}