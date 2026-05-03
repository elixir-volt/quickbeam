#!/usr/bin/env bash
set -euo pipefail

mix compile --warnings-as-errors >/tmp/quickbeam-autoresearch-compile.log 2>&1 || {
  tail -80 /tmp/quickbeam-autoresearch-compile.log
  exit 1
}

mix test test/js/bytecode_compiler_test.exs >/tmp/quickbeam-autoresearch-js-bytecode-test.log 2>&1 || {
  tail -80 /tmp/quickbeam-autoresearch-js-bytecode-test.log
  exit 1
}

mix run bench/js_bytecode_compiler_compat.exs >/tmp/quickbeam-autoresearch-js-bytecode-compat.log 2>&1 || {
  tail -80 /tmp/quickbeam-autoresearch-js-bytecode-compat.log
  exit 1
}

mix lint >/tmp/quickbeam-autoresearch-lint.log 2>&1 || {
  tail -80 /tmp/quickbeam-autoresearch-lint.log
  exit 1
}
