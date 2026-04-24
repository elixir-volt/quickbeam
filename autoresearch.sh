#!/bin/bash
set -euo pipefail

# Quick sanity check — compile and run core tests
if ! MIX_ENV=test mix compile --no-optional-deps --no-deps-check 2>&1 | tail -1 | grep -q "Generated\|Compiled"; then
  ERRORS=$(MIX_ENV=test mix compile --no-optional-deps --no-deps-check 2>&1 | grep -c "error:" || true)
  if [ "$ERRORS" -gt 0 ]; then
    echo "METRIC failing_tests=9999"
    exit 1
  fi
fi

MIX_ENV=test mix test test/vm/beam_compat_test.exs test/vm/compiler_test.exs --no-color --no-deps-check 2>&1 | tail -1 | grep -q "0 failures" || {
  echo "METRIC failing_tests=9999"
  echo "METRIC passing_tests=0"
  echo "Core tests failed — regression!"
  exit 1
}

# Run test262 suite
START=$(date +%s)
OUTPUT=$(MIX_ENV=test mix test test/vm/test262_test.exs --include test262 --max-cases 8 --no-color --no-deps-check 2>&1 | tail -5 || true)
END=$(date +%s)
ELAPSED=$((END - START))

# Parse: "2494 tests, N failures, M skipped"
FAILURES=$(echo "$OUTPUT" | grep -oE '[0-9]+ failures' | grep -oE '[0-9]+' || echo "9999")
PASSING=$(echo "$OUTPUT" | grep -oE '[0-9]+ tests' | head -1 | grep -oE '[0-9]+' || echo "0")
SKIPPED=$(echo "$OUTPUT" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' || echo "0")

# Calculate actual passing
ACTUAL_PASSING=$((PASSING - FAILURES - SKIPPED))

echo "METRIC failing_tests=$FAILURES"
echo "METRIC passing_tests=$ACTUAL_PASSING"
echo "METRIC skipped_tests=$SKIPPED"
echo "METRIC run_time_s=$ELAPSED"
echo ""
echo "Results: $ACTUAL_PASSING passing, $FAILURES failing, $SKIPPED skipped (${ELAPSED}s)"
