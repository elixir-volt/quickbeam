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
  quickjs_audit)
    bench_output=$(mix run bench/js_parser_quickjs_audit.exs 2>&1)
    ;;
  vm_compiler_audit)
    bench_output=$(mix run bench/vm_compiler_compat.exs 2>&1)
    ;;
  vm_compiler_corpus)
    bench_output=$(mix run bench/vm_compiler_corpus.exs 2>&1)
    ;;
  vm_compiler_opcodes)
    bench_output=$(mix run bench/vm_compiler_opcode_coverage.exs 2>&1)
    ;;
  vm_compiler_perf)
    bench_output=$(mix run bench/vm_compiler_perf.exs 2>&1)
    ;;
  vm_compiler_semantics)
    bench_output=$(mix run bench/vm_compiler_semantic_gaps.exs 2>&1)
    ;;
  quickjs_audit_exunit)
    set +e
    bench_output=$(mix test test/js/parser/quickjs_acceptance_audit_test.exs --only quickjs_acceptance_audit --formatter ExUnit.CLIFormatter 2>&1)
    bench_status=$?
    set -e

    if printf '%s\n' "$bench_output" | grep -qE '== Compilation error'; then
      printf '%s\n' "$bench_output"
      exit "$bench_status"
    fi

    bench_summary=$(printf '%s\n' "$bench_output" | grep -E '[0-9]+ tests?, [0-9]+ failures?' | tail -1)

    if [[ -z "${bench_summary:-}" ]]; then
      printf '%s\n' "$bench_output"
      exit "$bench_status"
    fi
    quickjs_acceptance_files=$(printf '%s\n' "$bench_summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^tests?,?$/) { print $(i - 1); exit } }')
    quickjs_acceptance_mismatches=$(printf '%s\n' "$bench_summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^failures?,?$/) { print $(i - 1); exit } }')
    quickjs_acceptance_files=${quickjs_acceptance_files:-0}
    quickjs_acceptance_mismatches=${quickjs_acceptance_mismatches:-0}

    bench_output=$(printf '%s\nMETRIC quickjs_acceptance_files=%s\nMETRIC quickjs_acceptance_mismatches=%s\n' \
      "$bench_output" "$quickjs_acceptance_files" "$quickjs_acceptance_mismatches")
    ;;
  quickjs_audit_sweep)
    total_files=0
    total_mismatches=0
    failed=0
    sweep_output=""

    for offset in $(seq "${AUDIT_OFFSET:-0}" "${AUDIT_LIMIT:-2000}" "${AUDIT_SWEEP_MAX_OFFSET:-52000}"); do
      set +e
      chunk_output=$(AUDIT_OFFSET="$offset" AUDIT_LIMIT="${AUDIT_LIMIT:-2000}" AUDIT_FILE_TIMEOUT="${AUDIT_FILE_TIMEOUT:-5000}" \
        mix test test/js/parser/quickjs_acceptance_audit_test.exs --only quickjs_acceptance_audit --formatter ExUnit.CLIFormatter 2>&1)
      chunk_status=$?
      set -e

      if printf '%s\n' "$chunk_output" | grep -qE '== Compilation error'; then
        printf '%s\n' "$chunk_output"
        exit "$chunk_status"
      fi

      chunk_summary=$(printf '%s\n' "$chunk_output" | grep -E '[0-9]+ tests?, [0-9]+ failures?' | tail -1)

      if [[ -z "${chunk_summary:-}" ]]; then
        printf '%s\n' "$chunk_output"
        exit "$chunk_status"
      fi

      chunk_files=$(printf '%s\n' "$chunk_summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^tests?,?$/) { print $(i - 1); exit } }')
      chunk_mismatches=$(printf '%s\n' "$chunk_summary" | awk '{ for (i = 1; i <= NF; i++) if ($i ~ /^failures?,?$/) { print $(i - 1); exit } }')
      chunk_files=${chunk_files:-0}
      chunk_mismatches=${chunk_mismatches:-0}
      total_files=$((total_files + chunk_files))
      total_mismatches=$((total_mismatches + chunk_mismatches))

      sweep_output=$(printf '%s\nAUDIT_CHUNK offset=%s files=%s mismatches=%s status=%s' \
        "$sweep_output" "$offset" "$chunk_files" "$chunk_mismatches" "$chunk_status")

      if [[ "$chunk_status" -ne 0 ]]; then
        failed=1
        sweep_output=$(printf '%s\n%s' "$sweep_output" "$chunk_output")
      fi
    done

    bench_output=$(printf '%s\nMETRIC quickjs_acceptance_files=%s\nMETRIC quickjs_acceptance_mismatches=%s\n' \
      "$sweep_output" "$total_files" "$total_mismatches")

    if [[ "$failed" -ne 0 ]]; then
      printf '%s\n' "$bench_output"
      exit 2
    fi
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
