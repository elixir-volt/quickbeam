# Autoresearch Ideas

## Current goal

Drive BEAM interpreter/compiler behavior toward QuickJS NIF parity on Test262, prioritizing categories where the native QuickJS path accepts the test and the BEAM paths still diverge.

## Active workload

Continue with adjacent QuickJS-accepted object-model slices. The next active candidate is `built-ins/TypedArray`:

```sh
AUTORESEARCH_QUICKJS_PARITY_ALL=1 AUTORESEARCH_TEST262_CATEGORY=built-ins/Boolean,built-ins/Number,built-ins/String,built-ins/Symbol,built-ins/BigInt TEST262_ERROR_LIMIT=80 ./autoresearch.sh
```

Latest completed result:

```text
category=built-ins/Array
compatibility_cases=2970
compatibility_pass=2970
compatibility_failures=0
both_fail=0
interpreter_fail_compiler_pass=0
compiler_fails=0
compiler_crashes=0
compiler_errors=0
```

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

### 1. Continue adjacent object-model parity

Recently completed slices:

```text
built-ins/Object: 3408/3408
built-ins/Reflect: 153/153
built-ins/Function: 495/495
```

Current active candidate:

```sh
AUTORESEARCH_QUICKJS_PARITY_ALL=1 AUTORESEARCH_TEST262_CATEGORY=built-ins/Boolean,built-ins/Number,built-ins/String,built-ins/Symbol,built-ins/BigInt TEST262_ERROR_LIMIT=80 ./autoresearch.sh
```

Latest completed Array result:

```text
compatibility_cases=2970
compatibility_pass=2970
compatibility_failures=0
both_fail=0
interpreter_fail_compiler_pass=0
compiler_fails=0
```

The `built-ins/Object` QuickJS-accepted slice is clean at `3408/3408`. The adjacent `built-ins/Reflect` slice is also clean at `153/153`; fixes covered abrupt `ToPropertyKey` ordering in `Reflect.defineProperty` and preserving `Reflect.get` receiver through prototype accessors.

Function slice progress:

- Set ECMA lengths for `Function.prototype.apply`, `bind`, `call`, and `Symbol.hasInstance`; failures dropped `45 → 40`.
- Prevented dynamic `Function(...)` calls inside outer constructors from inheriting the caller construction target prototype; failures dropped `40 → 32`.
- Treated non-strict function legacy `caller`/`arguments` reads that resolve to `undefined` as explicit own properties, avoiding fall-through to `Function.prototype` ThrowTypeError accessors; failures dropped `32 → 11`.
- Direct calls to non-strict bytecode functions now use the function realm/global object as `this`, not the caller's active receiver; failures dropped `11 → 7`.
- Direct eval cleanup preserves unrelated global object side effects from nested calls while still cleaning eval-created declared/assigned names; failures dropped `7 → 3`.
- `Object.defineProperty` on callable virtual `length`/`name` metadata now uses those virtual descriptors as existing attributes; failures dropped `3 → 0`.

The `built-ins/Function` QuickJS-accepted slice is clean at `495/495`. The `built-ins/Array` QuickJS-accepted slice is clean at `2970/2970`; fixes covered Array method arities, iterator identity, generic typed-array length handling, copyWithin ordinary property semantics, and BigInt locale-string lookup.

TypedArray full-category baseline was too slow for a tight loop (`~423s`, 34 failures, checks timed out). Use focused sub-slices instead:

- `built-ins/TypedArray/prototype/reduce,built-ins/TypedArray/prototype/reduceRight` is clean at `92/92`; fix was closure-aware mapped arguments offsets.
- `built-ins/TypedArray/prototype/join,built-ins/TypedArray/prototype/toString` is clean at `29/29`; fix was Number prototype lookup for `NaN`/`±Infinity`.
- `built-ins/TypedArray/prototype/Symbol.iterator` rechecked clean at `1/1`.

Current focused TypedArray species slice:

```text
category=built-ins/TypedArray/prototype/filter,built-ins/TypedArray/prototype/map,built-ins/TypedArray/prototype/slice
compatibility_cases=236
compatibility_pass=236
compatibility_failures=0
both_fail=0
interpreter_fail_compiler_pass=0
```

Kept fixes in TypedArray follow-up:

- `reduce`/`reduceRight` clean at `92/92`; closure-aware mapped arguments offsets.
- `join`/`toString` clean at `29/29`; Number prototype lookup for `NaN`/`±Infinity`.
- Species `filter`/`map`/`slice` is clean at `236/236`; fixes covered length-tracking views over unaligned resizable ArrayBuffers and preventing outer constructor `new.target` from making ordinary `BigInt()` calls throw.

TypedArray `set` is clean at `100/100`; the timeout was dominated by repeated post-call global object refresh scans, now cached until persistent globals or raw `globalThis` storage changes. The broader `built-ins/TypedArray` QuickJS-accepted category is clean at `1302/1302`; final residuals were prototype method identity aliases for `Symbol.iterator`/`values` and `toString`/`Array.prototype.toString`. Next adjacent candidate is ArrayBuffer/DataView resizable-buffer parity.

ArrayBuffer/DataView slice is clean at `666/666`; kept fixes cover `ArrayBuffer.isView`, prototype accessors and `@@toStringTag`, size validation, transfer/transferToFixedLength sizing and mutability order, slice receiver/index/default-end handling, species construction, in-place initialization of constructed ArrayBuffers for `newTarget` prototype semantics, explicit null species constructors, and maxByteLength ordering before `newTarget.prototype` lookup.

Map/Set slice is clean at `585/585`; residuals were prototype function identity aliases for `Map.prototype[Symbol.iterator] === Map.prototype.entries` and `Set.prototype.keys === Set.prototype.values === Set.prototype[Symbol.iterator]`. Next adjacent candidate is WeakMap/WeakSet. WeakMap/WeakSet is also clean at `224/224`. Next active candidate is Promise. Promise is clean at `281/281`; residuals were static method arities for `resolve`, `reject`, `all`, `allSettled`, `any`, and `race`. Next active candidate is RegExp. Full RegExp category crashed with exit 139, so the stable `built-ins/RegExp/prototype` sub-slice was used and is clean at `474/474`; fixes covered prototype method arities and compatible RegExp clone source validation. Next active candidate is Date. Date is clean at `583/583`; fixes covered setter/toJSON arities and the non-writable `Date.prototype[Symbol.toPrimitive]` descriptor fallback. Error constructors are already clean at `55/55`. JSON is already clean at `163/163`. Math is already clean at `327/327`. Broad all-in-one cumulative checkpoint currently exhausts BEAM literal memory, so it was split into shards. Shard 1 (`language/expressions/object`, `language/expressions/call`, Object, Reflect, Function) is clean at `5082/5082` after fixing function-kind constructor metadata, proxy revocation during nested `get`, and descriptor field lookup during prototype traversal. Array is clean at `2970/2970`, TypedArray at `1302/1302`, ArrayBuffer/DataView at `666/666`, and the collections/misc shard at `2218/2218`. Next active candidate is primitive wrappers.

Tried and reverted as ineffective:

- syncing captured locals in interpreter `catch_and_dispatch` throw branches did not improve the non-object invalid count cases because compiler also fails and the captured update is deeper than the caller frame.
- avoiding stale `arguments` globals/fallback cached arguments objects did not improve `Object.keys(arguments)` or the active metric.
- preserving symbol order for object/array assignment only improved the metric when paired with descriptor result key-order storage.
- changing compiler catch handler context to `RuntimeState.current_or(ctx)` did not improve the `defineProperty(arguments)` cluster.
- forcing compiler calls with arguments-object arguments through interpreter fallback did not improve the `defineProperty(arguments)` cluster; generated/runtime call paths still observe the stale/missing descriptor.
- forcing functions whose source mentions `arguments` through interpreter fallback at invocation did not improve the `defineProperty(arguments)` cluster.
- ignoring stale `arguments` entries in interpreter `ArgumentsObject.get/3` did not fix the former `Object.keys(arguments)` case; the actual fix was narrower `in`-operator frame sync.
- broad compiler fallbacks for mapped arguments were unnecessary for the final Object slice fix; preserving local `arguments` during frame/global sync fixed the residual cluster.
- removing `strict_active_caller?/1` from `Function.caller` did not improve the Function caller cluster by itself; the actual fix was explicit-own handling for non-strict legacy `caller`/`arguments` values.
- adding a virtual `length`/`name` static descriptor fallback in `Define.property/4` did not improve the bound function length cluster because the first define still stored non-configurable attrs.
- refreshing globals before dynamic `Function` compilation did not fix the interpreter-only global-this receiver issue; the useful fixes were direct-call `this` selection plus eval global-object side-effect cleanup.

### 2. Completed direct eval with spread

The direct eval spread residuals were fixed by restoring `globalThis` object properties alongside persistent globals when eval assignments resolve to caller locals. Kept regression tests cover direct eval with and without spread.

Tried and reverted as ineffective:

- treating `apply_eval` operand `0` as current scope instead of subtracting one; it did not improve the metric and left the global write wrong.

### 3. Completed object-expression side effects

The previous `language/expressions/object` QuickJS-accepted slice is clean at `941/941`. The kept fix refreshes global object writes after caught calls and updates the persistent global snapshot so later var declarations do not restore stale values.

### 4. Expand category slices only when useful

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
