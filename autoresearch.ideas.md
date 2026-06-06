# Autoresearch Ideas

## Current goal

Drive BEAM interpreter/compiler behavior toward QuickJS NIF parity on Test262, prioritizing categories where the native QuickJS path accepts the test and BEAM execution still diverges.

## Recently cleaned / do not re-baseline as active work unless a shard regresses

- Object / Reflect / Function / Array / String / Number / TypedArray / TypedArrayConstructors / Uint8Array / ArrayBuffer / DataView / collections / Promise / RegExp prototype / Date / Error / JSON / Math / primitive wrappers / WeakRef / FinalizationRegistry / SharedArrayBuffer / Atomics / Iterator / Proxy / global numeric / small global value and URI semantic slices are already cleaned or checkpointed.
- AsyncFunction, AsyncGeneratorPrototype, AsyncGeneratorFunction, GeneratorFunction, and GeneratorPrototype are clean in combination.
- Array/Map/Set/String iterator prototypes are clean.
- AsyncIteratorPrototype / AsyncFromSyncIteratorPrototype / RegExpStringIteratorPrototype are clean.
- AggregateError / NativeErrors / SuppressedError / ThrowTypeError are clean.
- DisposableStack / AsyncDisposableStack currently have no QuickJS-accepted cases in this configuration; skip until native support changes.

## Promising next paths

- Run cumulative shards periodically instead of all-in-one broad checkpoint; all-in-one can exhaust BEAM literal memory.
- Revisit URI timeout-only cases only with a structural loop/global synchronization optimization. Current URI baseline is 167/173, with six interpreter-timeout-only failures in decodeURI/decodeURIComponent/encodeURI/encodeURIComponent generated range tests; compiler passes all accepted URI cases. Do not retry isolated URI/fromCharCode micro-optimizations; they reduced elapsed time but not the primary timeout metric.
- Class statement/expression combined slice honest baseline is now 238 failures after removing the class-field eval source-regex workaround. Done fixes still worth preserving: constructor static accessor get/set merging, callable static setters, descriptor-based callable static fields, non-writable/non-configurable class constructor `prototype` descriptors, class-field direct-eval context propagation, repeated derived `this` initialization rejection, interpreter-side derived `this` TDZ capture propagation, repeated `super()` through captured `this` cells, private-symbol function name formatting, constructor-predicate class heritage validation, for-in enumeration of callable static fields with assigned values, centralized class-field eval AST recovery, and internal heap metadata for pending private-brand construction state. Remaining clusters: supercall/superproperty eval routing, compiler-only indirect eval `arguments`, static field descriptor/enumeration model, private-brand multiple-evaluation identity, and private generator interpreter-only failure.

## Do not retry unchanged

- Filename/source-string/harness special cases.
- Test262 input edits.
- Broad object-model changes that bypass `ObjectModel.InternalMethods`.
- Full `built-ins/RegExp`; use sub-slices because the full category previously crashed.
- Naive TypedArray bulk-write optimization for `set`.
- Re-enabling compiled generator execution without a full continuation semantics audit. The conservative fallback through the interpreter is what cleaned the generator slice after interpreter reentry/throw semantics were fixed.
- Isolated URI non-BMP decode/fromCharCode fast paths without broader dispatch/global-sync work.
- Broad regex-based typed-array non-integer CanonicalNumericIndexString classification. The exact ToNumber/ToString-style helper worked; avoid reverting to the older regex shape that misclassified non-canonical strings such as `1.0`.
- Typed-array Reflect.set/receiver result refactor without descriptor-based receiver writes. The final fix needed `[[DefineOwnProperty]]`-style receiver writes to avoid prototype recursion; do not retry the result-only refactor.
- Generic compiler RuntimeState/fast-context installation or proxy-trap interpreter fallback for Proxy trap context. Tried after Proxy baseline and the primary metric stayed at 12. The actual fix was making RuntimeABI global reads prefer persistent globals, matching RuntimeHelpers, so do not retry trap dispatch or handler identity work unchanged.
- Naive compiler eval lowering change that treats `op_eval` with no scope operands as indirect eval. It did not improve the class slice and `compiler_fails` stayed at 17; first inspect QuickJS eval/apply_eval operands and direct-vs-indirect helper semantics.
- Blind `put_field` → `define_field` substitution for static class fields. It fixed focused descriptors but failed checks due compiler stack/test behavior and did not improve the active metric. Also do not retry the simple `apply_eval scope_idx_raw == 0` split unchanged; focused probe passed but full metric stayed unchanged.
- Broad `has_prototype: false` rejection for class heritage. It fixed focused arrow-superclass probes but regressed the class slice from 233 to 288; use a precise constructability predicate or arrow/async-arrow detection if revisiting class heritage.
- Public static field anonymous-name lowering alone. Focused public-field probe passed but active metric stayed unchanged; the kept fix was private-symbol name formatting.
- Descriptor-key/static-field enumeration broad rewrites using `InternalMethods.own_keys` for callable for-in. A narrow callable clause for assigned static fields improved the class slice, but attempts to include descriptor-only keys via callable `InternalMethods.own_keys` caused focused interpreter issues and did not fix `static-field-declaration.js`; revisit only with a precise callable for-in key-order/descriptor model.
- Class-field eval `new.target` / `super` normalization must not use source regex or source-string rewriting. The previous regex workaround was removed; implement this by carrying eval context and evaluating parsed AST/bytecode semantics directly. Top-level `(0, eval)("super.x")` can match separately, but class-field eval failures route through DirectEval/opcode paths; inspect `op_eval`/`op_apply_eval` and `call1` eval lowering before retrying.
- Passing current globals into global `js_eval` unchanged. It preserved ordinary eval-spread but regressed focused class-field indirect `arguments` in interpreter and still did not fix compiler; the remaining compiler-only `arguments` cases need a precise direct-vs-indirect eval lowering/runtime-state fix rather than a global eval context broadening.
- Broad closure-specific constructor/private static storage. Making generic closure constructor keys or routing all callable private fields/brands through closure-specific process keys fixed a focused private static field cross-class probe but broke first-party private static method/ordinary private method access. The underlying class-factory multiple-evaluation issue is likely shared captured private-name cells or prototype/method closure identity; do not retry storage-key-only changes unchanged.
