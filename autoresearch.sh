#!/usr/bin/env bash
set -euo pipefail

bytecode_test_output=$(mix test test/js/bytecode_compiler_test.exs --formatter ExUnit.CLIFormatter 2>&1)
printf '%s\n' "$bytecode_test_output"

frontier_output=$(mix run bench/js_bytecode_compiler_frontier.exs 2>&1)
printf '%s\n' "$frontier_output"

compat_output=$(mix run bench/js_bytecode_compiler_compat.exs 2>&1)
printf '%s\n' "$compat_output"

printf '%s\n' "$frontier_output" | grep '^METRIC '
printf '%s\n' "$compat_output" | grep '^METRIC '
