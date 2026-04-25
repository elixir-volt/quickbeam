#!/bin/bash
set -euo pipefail

# Core tests must still pass
MIX_ENV=test mix test test/vm/beam_compat_test.exs test/vm/compiler_test.exs --no-color --no-deps-check 2>&1 | tail -1 | grep -q "0 failures" || {
  echo "METRIC failing_tests=9999"
  echo "Core tests failed — regression!"
  exit 1
}

# Run ALL beam web API tests
OUTPUT=$(MIX_ENV=test mix test test/web_apis/beam_*_test.exs --include beam_web_apis --no-color --no-deps-check 2>&1 | tail -5 || true)

TOTAL=$(echo "$OUTPUT" | grep -oE '[0-9]+ tests?' | grep -oE '[0-9]+' || echo "0")
FAILURES=$(echo "$OUTPUT" | grep -oE '[0-9]+ failures?' | grep -oE '[0-9]+' || echo "$TOTAL")
PASSING=$((TOTAL - FAILURES))

echo "METRIC failing_tests=$FAILURES"
echo "METRIC passing_tests=$PASSING"
echo ""
echo "Results: $PASSING passing, $FAILURES failing out of $TOTAL tests"
