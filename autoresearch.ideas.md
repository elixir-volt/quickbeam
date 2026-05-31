# Autoresearch Ideas

## Current goal

Drive BEAM interpreter/compiler behavior toward QuickJS NIF parity on Test262, prioritizing categories where the native QuickJS path accepts the test and the BEAM paths still diverge.

## Active workload

Start with the bounded Proxy slice because recent work reduced it sharply and the remaining failures are clustered in object-model semantics:

```sh
AUTORESEARCH_TEST262_CATEGORY=built-ins/Proxy TEST262_LIMIT=300 TEST262_ERROR_LIMIT=20 ./autoresearch.sh
```

Latest result:

```text
compatibility_cases=300
compatibility_pass=300
compatibility_failures=0
both_fail=0
interpreter_fail_compiler_pass=0
compiler_fails=0
compiler_crashes=0
compiler_errors=0
```

Proxy slice is clean. Kept fixes:

- interpreter `in` now uses ToPropertyKey and refreshes frame-visible global writes after proxy `has` traps;
- proxy newTarget default-prototype lookup recurses to the target function realm;
- Test262 realm objects expose `evalScript` that evaluates in the created realm.

## Efficient loop

1. Run the active bounded slice once to identify the current failure list.
2. Pick one cluster only.
3. Reproduce with a small focused `.exs` or a single Test262 file before editing.
4. Add a focused regression test in `test/vm/...` only when the fix is semantic and stable.
5. Validate with the smallest useful commands first:
   ```sh
   mix test test/vm/object_model/proxy_test.exs --max-failures 5
   AUTORESEARCH_TEST262_CATEGORY=built-ins/Proxy TEST262_LIMIT=300 TEST262_ERROR_LIMIT=20 ./autoresearch.sh
   ```
6. Run broad checks only after a metric improvement or before committing:
   ```sh
   mix format --check-formatted
   mix reach.check
   mix test test/vm/runtime test/vm/compiler test/vm/object_model test/vm/interpreter \
     test/vm/object_refactor_semantics_test.exs test/vm/iterator_semantics_test.exs \
     test/vm/builtin_dsl_test.exs test/vm/ecma_metadata_test.exs --max-failures 5
   ```
7. Full source-built suite is periodic, not per tiny probe:
   ```sh
   QUICKBEAM_BUILD=1 mix test --max-failures 1 --timeout 120000
   ```

For `run_experiment`, use a larger checks timeout because current backpressure checks exceed 300s on this branch:

```text
checks_timeout_seconds: 900
```

## Near-term plan

### 1. Move to native-accepted QuickJS parity batches

Proxy is clean, so switch from category slices to QuickJS-accepted residuals:

```sh
AUTORESEARCH_QUICKJS_PARITY=1 ./autoresearch.sh
```

Use this to avoid spending time on tests QuickJS itself rejects or does not support.

### 2. Expand category slices only when useful

Use bounded slices for focused subsystems, not broad unrelated sweeps:

```sh
AUTORESEARCH_TEST262_CATEGORY=built-ins/Object TEST262_LIMIT=1000 ./autoresearch.sh
AUTORESEARCH_TEST262_CATEGORY=built-ins/TypedArray TEST262_LIMIT=500 ./autoresearch.sh
AUTORESEARCH_TEST262_CATEGORY=language/expressions/object TEST262_LIMIT=1000 ./autoresearch.sh
AUTORESEARCH_TEST262_CATEGORY=language/expressions/call TEST262_LIMIT=1000 ./autoresearch.sh
```

Only reinitialize the experiment when changing the active workload baseline.

## Do not retry unchanged

- Broad object-model changes that bypass `InternalMethods`.
- Filename/source-string special cases.
- Full category sweeps after every small edit.
- Old stale category notes from previous Array/Object/Function/Date/etc. campaigns unless a current run reproduces them.
- QuickJS bytecode/parser parity work in this branch unless the active Test262 failure is definitely caused before BEAM execution.
