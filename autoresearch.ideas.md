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
- Class statement/expression combined slice is active and improved from 368 to 264 failures. Done fixes: constructor static accessor get/set merging, callable static setters, descriptor-based callable static fields, and non-writable/non-configurable class constructor `prototype` descriptors. Remaining visible clusters are mostly eval-inside-class-field early-error/indirect-eval cases, derived `this` TDZ during field initialization, and compiler-only indirect eval `arguments` cases.

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
