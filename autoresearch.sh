#!/usr/bin/env bash
set -euo pipefail

category="${AUTORESEARCH_TEST262_CATEGORY:-language/expressions/object}"
error_limit="${TEST262_ERROR_LIMIT:-12}"
case_timeout="${TEST262_CASE_TIMEOUT:-5000}"

export QUICKBEAM_BUILD=1
export TEST262_CATEGORY="$category"
export TEST262_ERROR_LIMIT="$error_limit"
export TEST262_CASE_TIMEOUT="$case_timeout"

if [[ -n "${TEST262_LIMIT:-}" ]]; then
  export TEST262_LIMIT
fi

start_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)

output=$(mix run bench/vm_compiler_test262.exs)
printf '%s\n' "$output"

metric() {
  local name="$1"
  printf '%s\n' "$output" | awk -F= -v key="METRIC ${name}" '$1 == key {print $2}' | tail -1
}

cases=$(metric compiler_test262_cases)
pass=$(metric compiler_test262_pass)
failures=$(metric compiler_test262_failures)
compiler_errors=$(metric compiler_test262_compiler_errors)
compiler_crashes=$(metric compiler_test262_compiler_crashes)
compiler_fails=$(metric compiler_test262_compiler_fails)
both_fail=$(metric compiler_test262_both_fail)
interpreter_fail_compiler_pass=$(metric compiler_test262_interpreter_fail_compiler_pass)

end_ms=$(python3 - <<'PY'
import time
print(int(time.time() * 1000))
PY
)
elapsed_ms=$((end_ms - start_ms))

printf 'ASI active_category=%s\n' "$category"
printf 'ASI case_timeout_ms=%s\n' "$case_timeout"
printf 'METRIC compatibility_failures=%s\n' "$failures"
printf 'METRIC compatibility_pass=%s\n' "$pass"
printf 'METRIC compatibility_cases=%s\n' "$cases"
printf 'METRIC compiler_errors=%s\n' "$compiler_errors"
printf 'METRIC compiler_crashes=%s\n' "$compiler_crashes"
printf 'METRIC compiler_fails=%s\n' "$compiler_fails"
printf 'METRIC both_fail=%s\n' "$both_fail"
printf 'METRIC interpreter_fail_compiler_pass=%s\n' "$interpreter_fail_compiler_pass"
printf 'METRIC elapsed_ms=%s\n' "$elapsed_ms"
