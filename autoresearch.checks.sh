#!/usr/bin/env bash
set -euo pipefail

export QUICKBEAM_BUILD=1

mix compile --warnings-as-errors >/dev/null
mix test test/js/compiler_test.exs test/vm/compiler_test.exs test/quickbeam_test.exs >/dev/null
mix run bench/vm_compiler_test262.exs | tail -20
JS_COMPILER_EXISTING_OFFSET=0 JS_COMPILER_EXISTING_LIMIT=5000 mix run bench/js_compiler_existing_corpus.exs | tail -20
mix run bench/js_compiler_frontier.exs | tail -20
