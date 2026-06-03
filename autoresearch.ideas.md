# Autoresearch Ideas

## Current goal

Drive BEAM interpreter/compiler behavior toward QuickJS NIF parity on Test262, prioritizing categories where the native QuickJS path accepts the test and BEAM execution still diverges.

## Recently cleaned / do not re-baseline as active work unless a shard regresses

- Object / Reflect / Function / Array / TypedArray / ArrayBuffer / DataView / collections / Promise / RegExp prototype / Date / Error / JSON / Math / primitive wrappers / WeakRef / FinalizationRegistry / SharedArrayBuffer / Atomics / Iterator / global numeric and URI semantic slices are already cleaned or checkpointed.
- AsyncFunction, AsyncGeneratorPrototype, AsyncGeneratorFunction are clean in combination.
- Array/Map/Set/String iterator prototypes are clean.
- AsyncIteratorPrototype / AsyncFromSyncIteratorPrototype / RegExpStringIteratorPrototype are clean.
- AggregateError / NativeErrors / SuppressedError / ThrowTypeError are clean.
- DisposableStack / AsyncDisposableStack currently have no QuickJS-accepted cases in this configuration; skip until native support changes.

## Promising next paths

- Finish the remaining GeneratorPrototype semantic tail (`7` shared failures): reentrancy and `.throw(...)` through nested `try/catch/finally`. Previous naive executing-state marking did not help because the focused probe resolved the outer `iter` binding as `undefined`; investigate generator-frame global/captured binding synchronization before retrying.
- Continue the active `TypedArrayConstructors,Uint8Array` slice. It improved from 192 to 106 failures after BYTES_PER_ELEMENT descriptors, constructor call rejection, inherited static-method ownership, integer-indexed key semantics, and Uint8Array `fromHex`/`fromBase64` statics. Remaining clusters are constructor/newTarget/species behavior, typed-array `from`/`of` result validation, residual integer-indexed Set/OwnPropertyKeys semantics, BigInt typed-array conversions, and two excessive-length timeouts.
- Probe other small unclean builtin families after the typed-array constructor slice slows down: `Infinity`, `NaN`, `undefined`, `ShadowRealm`, `AbstractModuleSource`.
- Run cumulative shards periodically instead of all-in-one broad checkpoint; all-in-one can exhaust BEAM literal memory.
- Revisit URI A2.5 timeout-only cases only with a structural loop/global synchronization optimization. Do not retry isolated URI/fromCharCode micro-optimizations; they reduced elapsed time but not the primary timeout metric.

## Do not retry unchanged

- Filename/source-string/harness special cases.
- Test262 input edits.
- Broad object-model changes that bypass `ObjectModel.InternalMethods`.
- Full `built-ins/RegExp`; use sub-slices because the full category previously crashed.
- Naive TypedArray bulk-write optimization for `set`.
- Isolated generator executing-state marker without first fixing the `iter` binding visibility inside resumed generator frames.
- Isolated URI non-BMP decode/fromCharCode fast paths without broader dispatch/global-sync work.
