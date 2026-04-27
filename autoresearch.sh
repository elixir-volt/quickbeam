#!/usr/bin/env bash
set -euo pipefail

run_parser_tests() {
  mix test test/js/parser --formatter ExUnit.CLIFormatter 2>&1
}

parser_output=$(run_parser_tests)
printf '%s\n' "$parser_output"

summary=$(printf '%s\n' "$parser_output" | grep -E '[0-9]+ tests?, [0-9]+ failures?' | tail -1)
parser_tests=$(printf '%s\n' "$summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^tests?,?$/) { print $(i - 1); exit } }')
quickjs_parser_tests=$(grep -REoh '@moduletag :quickjs_port|test "ports QuickJS' test/js/parser | wc -l | tr -d ' ')

seconds=$(printf '%s\n' "$parser_output" | sed -nE 's/Finished in ([0-9.]+) seconds.*/\1/p' | tail -1)
if [[ -n "${seconds:-}" ]]; then
  parser_test_ms=$(awk -v s="$seconds" 'BEGIN { printf "%.0f", s * 1000 }')
else
  parser_test_ms=0
fi

case "${PARSER_BENCH:-compat}" in
  compat)
    bench_output=$(mix run bench/js_parser_compat.exs 2>&1)
    ;;
  perf)
    bench_output=$(mix run bench/js_parser_perf.exs 2>&1)
    ;;
  *)
    echo "unknown PARSER_BENCH=${PARSER_BENCH}" >&2
    exit 2
    ;;
esac

printf '%s\n' "$bench_output"

printf 'METRIC quickjs_parser_tests=%s\n' "$quickjs_parser_tests"
printf 'METRIC parser_tests=%s\n' "$parser_tests"
printf 'METRIC parser_test_ms=%s\n' "$parser_test_ms"
printf '%s\n' "$bench_output" | grep '^METRIC '
