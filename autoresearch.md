# Autoresearch: QuickBEAM full JavaScript compatibility

## Objective
Drive QuickBEAM toward full JavaScript compatibility by reducing Test262 failures across the VM interpreter and BEAM compiler paths. The current phase targets broad `language/expressions/object` compatibility because it still exposes real runtime/compiler semantic gaps while the default VM compiler Test262 suite is clean.

The workload compares:

- interpreter mode: `QuickBEAM.eval(..., mode: :beam)`
- compiled mode: `QuickBEAM.eval(..., mode: :beam_compiler)`

A case is compatible only when both paths pass the Test262 expectation. Failures include shared runtime/interpreter failures, compiler-only failures, compiler crashes, and interpreter/compiler disagreement.

## Metrics
- **Primary**: `compatibility_failures` (count, lower is better) — total non-passing cases in the active Test262 compatibility workload.
- **Secondary**:
  - `compatibility_pass` — passing cases.
  - `compatibility_cases` — total cases in the workload.
  - `compiler_fails` — compiler-only semantic failures when interpreter passes.
  - `compiler_crashes` — compiler crashes when interpreter passes.
  - `compiler_errors` — unsupported/compiler-error outcomes when interpreter passes.
  - `both_fail` — shared interpreter/compiler failures, usually runtime/parser semantics.
  - `interpreter_fail_compiler_pass` — oracle skew or cases where source-compiled/direct-eval path passes while native bytecode interpreter path fails.

## How to Run

```sh
./autoresearch.sh
```

The script emits `METRIC name=value` lines. Defaults:

```sh
AUTORESEARCH_TEST262_CATEGORY=language/expressions/object
TEST262_ERROR_LIMIT=12
```

To move to the next compatibility phase, change `AUTORESEARCH_TEST262_CATEGORY`, for example:

```sh
AUTORESEARCH_TEST262_CATEGORY=language/expressions/function ./autoresearch.sh
AUTORESEARCH_TEST262_CATEGORY=language/expressions/array ./autoresearch.sh
AUTORESEARCH_TEST262_CATEGORY=language/expressions/call ./autoresearch.sh
AUTORESEARCH_TEST262_CATEGORY=built-ins/Object TEST262_LIMIT=500 ./autoresearch.sh
```

When changing the active workload, reinitialize the autoresearch experiment config with the same primary metric if the baseline materially changes.

## Files in Scope

Primary implementation areas:

- `lib/quickbeam/vm/interpreter.ex` and `lib/quickbeam/vm/interpreter/**` — VM bytecode interpreter semantics.
- `lib/quickbeam/vm/compiler/**` — BEAM compiler lowering, runtime helpers, analysis, and runner behavior.
- `lib/quickbeam/vm/object_model/**` — object/property/prototype/accessor semantics.
- `lib/quickbeam/vm/runtime/**` — built-in objects and Test262 runtime compatibility.
- `lib/quickbeam/js/compiler/**` — source compiler only when failures involve direct eval or source-compiled functions.
- `lib/quickbeam/js/parser/**` — parser/validation only for true syntax/early-error compatibility gaps.
- `test/vm/compiler_test.exs`, `test/js/compiler_test.exs`, and focused parser/runtime tests — regressions for fixed cases.
- `bench/vm_compiler_test262.exs` and support files — benchmark/audit instrumentation only when more signal is needed.

## Off Limits

- Do not edit Test262 inputs or harness files to make cases pass.
- Do not special-case benchmark filenames or exact Test262 source strings.
- Do not suppress failures in `bench/vm_compiler_test262.exs` unless the case is genuinely out-of-scope and documented.
- Do not bypass QuickJS/native bytecode validation or fabricate loadability.
- Do not introduce compatibility wrappers for renamed public modules.
- Do not use broad global-resolution changes that regress existing JS compiler corpora.
- Do not include `autoresearch.jsonl` or generated experiment logs in production PRs unless explicitly requested.

## Constraints

- Preserve current clean baselines:
  - `mix test test/js/compiler_test.exs test/vm/compiler_test.exs test/quickbeam_test.exs`
  - default `mix run bench/vm_compiler_test262.exs` remains zero failures.
  - JS compiler existing corpus remains zero mismatches.
  - JS compiler frontier remains zero mismatches.
- Use `QUICKBEAM_BUILD=1` for compile/test commands that may touch Zig/C or require a fresh NIF.
- Prefer focused semantic fixes and focused regression tests.
- Backpressure checks are authoritative: an improved metric with failed checks must be discarded or fixed before keep.
- ExDNA clone budget is zero.

## Current Baseline Before This Session

Latest object-suite status before autoresearch setup:

```text
TEST262_CATEGORY=language/expressions/object
compiler_test262_cases=946
compiler_test262_pass=841
compiler_test262_failures=105
compiler_test262_compiler_errors=0
compiler_test262_compiler_crashes=0
compiler_test262_compiler_fails=0
compiler_test262_both_fail=94
compiler_test262_interpreter_fail_compiler_pass=11
```

Recent wins already landed:

- `QuickBEAM.JSError` renamed to `QuickBEAM.JS.Error`.
- Source-compiled assignment expressions now preserve their assigned value.
- Object literal creation in BEAM compiler now uses the normal object prototype path.
- Object method `super` lookup works in compiled mode.
- Object-suite compiler failures/crashes dropped to zero for the current object workload.

## What's Been Tried

- Accessor property key-order preservation fixed real descriptor/key-order issues but did not solve shared accessor-name/prototype Test262 failures.
- Source-compiled direct eval currently passes some cases that the native bytecode interpreter fails. Treat `interpreter_fail_compiler_pass` as an oracle/path skew cluster, not a reason to regress compiler behavior.
- Object method `super` mismatch was caused by compiled object creation using `Heap.wrap(%{})` without the default object prototype. Fixed by lowering object creation through `RuntimeHelpers.new_object/1`.
- Assignment expressions in the source compiler previously emitted `put_*` without preserving expression value. Fixed with `dup` + non-pushing writes.

## Next Ideas

- Triage shared `both_fail` clusters in `language/expressions/object`, especially:
  - `__proto__-*` object literal prototype semantics.
  - accessor computed/literal numeric names returning `undefined` where getters/setters should be installed.
  - computed property key conversion errors (`ToPropertyKey`) for accessors.
- Investigate why native bytecode interpreter fails direct-eval accessor descriptor cases while source-compiled/direct-eval path passes.
- After object-suite failures drop substantially, rebaseline this same experiment against `language/expressions/function`, then `array`, `call`, and a bounded `built-ins/Object` slice.
