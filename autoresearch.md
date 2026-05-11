# Autoresearch: QuickBEAM full JavaScript compatibility

## Objective
Drive QuickBEAM toward full JavaScript compatibility by reducing Test262 failures across the VM interpreter and BEAM compiler paths. The current phase targets broad `language/expressions/object` compatibility because it still exposes real runtime/compiler semantic gaps while the default VM compiler Test262 suite is clean.

The active workload currently targets `language/expressions/array` after object-expression plateaued at 40 failures and function-expression reached 9 failures. The workload compares:

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
- Computed accessor keys and computed data property keys now use property-key normalization; bracket access and assignment now honor accessors. This removed large accessor/computed-property-name clusters.
- Computed `__proto__` now behaves more like an own data property by using descriptor metadata to distinguish it from the internal prototype slot.
- Object rest/spread copying now filters `enumerable: false` descriptor properties and invokes proxy `ownKeys`/`getOwnPropertyDescriptor` traps for object-copy observability.
- Internal object-literal prototype state is now hidden from `hasOwnProperty`, preserved separately from computed `['__proto__']` own data properties, and shorthand `__proto__` is treated as data-property syntax rather than the special prototype setter.
- Strict direct function calls now preserve `this === undefined` in both interpreter and compiled paths.
- Object methods without a prototype are rejected as constructors while class constructor bytecode is still accepted.
- Direct eval in non-strict functions now rejects `var` declarations that conflict with caller top-level lexical locals.
- Function objects now inherit Object.prototype methods through the Function.prototype fallback path, fixing `hasOwnProperty` access on methods.
- BigInt literal method keys are normalized from QuickJS tagged integer operands to string property keys.
- `bench/vm_compiler_test262.exs` now honors Test262 `onlyStrict` flags by prepending a strict directive before harness/test source; this corrected the function-expression workload baseline from 13 to 9 failures.
- Array instances now read methods from the cached `Array.prototype` object instead of constructing fresh builtin tuples; this fixed the `array.toString === Array.prototype.toString` identity cluster and reduced the array-expression workload from 33 to 25 failures.
- Array instances now fall back from the cached `Array.prototype` object to `Object.prototype`, preserving inherited methods like `hasOwnProperty` when read-only indexed properties exist on `Array.prototype`.
- Compiled builtin method calls now install the supplied compiled call context before invoking builtins; this eliminated the array spread/apply compiler-only `assert is not defined` cluster.
- Object spread now copies enumerable symbol keys in both interpreter and compiler paths.
- `Object.keys` and for-in enumeration now include own string/integer keys that are present on the object but absent from `key_order` metadata, fixing native-bytecode object-spread descriptor/getter skew.
- Discarded/check-failed ideas:
  - Broadly treating shape proto `nil` as null prototype regressed checks; need an explicit null-prototype representation.
  - Partial function `name`/`length` own descriptors did not reduce primary failures; needs coherent delete/write/hasOwnProperty semantics. Later static metadata attempts reduced `both_fail` but either left the primary metric unchanged or introduced compiler-only failures; a name-only variant still introduced compiler-only failures. Resetting metadata delete tombstones and method-only descriptor storage did not fix the compiler-only failures.
  - Partial symbol copying for proxy object spread shifted categories but did not reduce total failures, even when a focused symbol descriptor repro passed. A focused object-rest proxy destructuring probe currently does not invoke `ownKeys`/`getOwnPropertyDescriptor` at all with current stack semantics; OP_dup1 correction plus symbol-aware rest copying regressed, so exact copy mask/source/exclude handling needs inspection.
  - Throwing on null-prototype object `ToPropertyKey` for computed accessor names passed a focused repro but regressed the primary metric; avoid broad ordinary-object stringification changes.
  - Naively inserting `to_propkey` before computed-property values in decoded bytecode regressed heavily and did not fix the stale outer-local value read.
  - Adding Heap-level generator function prototype caches improved a focused interpreter repro but did not improve the primary metric because the compiled path still failed identity checks. A later variant with GeneratorFunction.prototype and generator method prototype descriptors also stayed flat at 40.
  - Broadly compiling interpreter direct eval through the source compiler still regresses the object workload, even though checks pass. Broad transient-global writeback from eval final context into caller locals and returning assigned globals through eval context both regressed despite fixing focused assignment repros.
  - Capturing whole `ctx.globals` on method definitions to fix eval-created accessors regressed and did not fix the focused native eval accessor case; the issue is narrower than missing global capture.
  - Tagging global variable references separately from local/captured cell references fixed a focused with/unscopables assignment probe, but did not reduce the function-expression workload. Updating local frame/captured state for the fallthrough reference also stayed flat and increased compiler-only failures; the slot mapping needs deeper inspection.
  - Preserving globals when converting fast invocation context maps and routing `Function.prototype.call/apply` through `Invocation.dispatch` did not reduce array spread/apply failures; the focused duplicate `callCount` issue remained.
  - Copying enumerable symbol keys in object spread fixed an interpreter-focused array symbol spread case but shifted the failure to compiler-only and did not reduce total array failures; source compiler spread needs matching symbol support.

## Next Ideas

- For the current `language/expressions/array` workload, only `spread-obj-spread-order.js` remains failing. Triage decoded object-spread bytecode/source representation before retrying copy-key ordering; a standalone ordering helper previously stayed flat by exposing `spread-obj-manipulate-outter-obj-in-getter.js`.
- For the function workload later, continue investigating callable `name`/`length` descriptors, compiler-only parameter destructuring scope, with/unscopables slot mapping, and static-block `await` identifier handling.
- For the object workload later, continue investigating native bytecode direct-eval accessor descriptor skew and exact proxy rest/spread excluded-name behavior.
- After array-suite failures drop substantially, rebaseline this same experiment against `language/expressions/call` and a bounded `built-ins/Object` slice.
