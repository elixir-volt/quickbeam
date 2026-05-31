# Autoresearch: QuickJS NIF parity on Test262

## Objective

Reduce Test262 compatibility gaps between the BEAM interpreter/compiler paths and the QuickJS NIF path. Prioritize tests that QuickJS accepts and where BEAM execution diverges, with focused bounded workloads to avoid wasting time on unrelated categories.

## Primary metric

- `compatibility_failures` — lower is better.

Secondary metrics:

- `compatibility_pass`
- `compatibility_cases`
- `compiler_errors`
- `compiler_crashes`
- `compiler_fails`
- `both_fail`
- `interpreter_fail_compiler_pass`
- `elapsed_ms`

## Current active workload

Bounded Proxy slice:

```sh
AUTORESEARCH_TEST262_CATEGORY=built-ins/Proxy TEST262_LIMIT=300 TEST262_ERROR_LIMIT=20 ./autoresearch.sh
```

Current local baseline:

```text
compatibility_cases=300
compatibility_pass=295
compatibility_failures=5
compiler_errors=0
compiler_crashes=0
compiler_fails=0
both_fail=3
interpreter_fail_compiler_pass=2
```

Known remaining residuals:

- `built-ins/Proxy/get-fn-realm.js`
- `built-ins/Proxy/get-fn-realm-recursive.js`
- `built-ins/Proxy/revocable/tco-fn-realm.js`
- interpreter-only `built-ins/Proxy/has/call-in-prototype-index.js`
- interpreter-only `built-ins/Proxy/has/trap-is-undefined-target-is-proxy.js`

## How to run

Normal active benchmark:

```sh
./autoresearch.sh
```

Active benchmark with explicit category:

```sh
AUTORESEARCH_TEST262_CATEGORY=built-ins/Proxy TEST262_LIMIT=300 TEST262_ERROR_LIMIT=20 ./autoresearch.sh
```

QuickJS-accepted residual mode:

```sh
AUTORESEARCH_QUICKJS_PARITY=1 ./autoresearch.sh
```

All QuickJS parity mode only when intentionally doing a broader pass:

```sh
AUTORESEARCH_QUICKJS_PARITY_ALL=1 ./autoresearch.sh
```

## Efficient workflow

1. Run one bounded slice and capture the failure list.
2. Pick one semantic cluster.
3. Build a focused repro before editing.
4. Make the smallest semantic fix.
5. Run the focused test and the active bounded slice.
6. Run architecture/format and the broad VM subset only after a likely improvement.
7. Run the full source-built suite periodically or before pushing a batch.

Recommended focused checks:

```sh
mix test test/vm/object_model/proxy_test.exs --max-failures 5
AUTORESEARCH_TEST262_CATEGORY=built-ins/Proxy TEST262_LIMIT=300 TEST262_ERROR_LIMIT=20 ./autoresearch.sh
```

Recommended batch validation:

```sh
mix format --check-formatted
mix reach.check
mix test test/vm/runtime test/vm/compiler test/vm/object_model test/vm/interpreter \
  test/vm/object_refactor_semantics_test.exs test/vm/iterator_semantics_test.exs \
  test/vm/builtin_dsl_test.exs test/vm/ecma_metadata_test.exs --max-failures 5
```

Full validation:

```sh
QUICKBEAM_BUILD=1 mix test --max-failures 1 --timeout 120000
```

When using `run_experiment`, set `checks_timeout_seconds` to at least `900`; current backpressure checks can exceed the default 300 seconds.

## Files in scope

- `lib/quickbeam/vm/object_model/**`
- `lib/quickbeam/vm/runtime/**`
- `lib/quickbeam/vm/interpreter/**`
- `lib/quickbeam/vm/compiler/**`
- focused tests under `test/vm/**`
- `bench/vm_compiler_test262.exs` only for instrumentation, not for hiding failures

## Off limits

- Do not edit Test262 inputs or harness files to make cases pass.
- Do not special-case filenames, exact source strings, or benchmark output.
- Do not suppress failures unless they are explicitly out of scope and documented.
- Do not run broad unrelated suites after every small edit.
- Do not keep stale category notes as active strategy; rebaseline before acting on old notes.
