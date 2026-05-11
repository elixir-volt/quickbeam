#!/usr/bin/env bash
set -euo pipefail

export QUICKBEAM_BUILD=1

run_check() {
  local name="$1"
  shift

  local start
  start=$(date +%s)
  echo "[checks] start ${name}"

  "$@"

  local end
  end=$(date +%s)
  echo "[checks] done ${name} ($((end - start))s)"
}

run_check "compile" mix compile --warnings-as-errors
run_check "core tests" mix test test/js/compiler_test.exs test/vm/compiler_test.exs test/quickbeam_test.exs
run_check "default vm compiler test262" bash -c 'mix run bench/vm_compiler_test262.exs | tail -20'
run_check "existing JS compiler corpus" bash -c 'JS_COMPILER_EXISTING_OFFSET=0 JS_COMPILER_EXISTING_LIMIT=5000 mix run bench/js_compiler_existing_corpus.exs | tail -20'
run_check "JS compiler frontier" bash -c 'mix run bench/js_compiler_frontier.exs | tail -20'
