# Bounded object-shape investigation

This report evaluates owner-local hidden classes after compact default property
descriptors had already removed most descriptor allocation. The prototype is
preserved on branch `hidden-object-shapes` at commit `fc609df9` and is rejected
for the release path.

## Opportunity probe

A temporary completed-evaluation probe grouped final Vue 3.5.39 objects by
ordered default binary keys. It did not mutate shared state and was removed after
measurement.

- total heap objects: 1,130;
- ordinary objects: 361;
- objects containing only shape-eligible default binary properties: 82;
- distinct eligible final shapes: 40;
- empty eligible objects: 29;
- most frequent non-empty shape: five 27-field Vue VNodes;
- most other eligible shapes occurred once to four times.

Only 7.3% of all objects and 22.7% of ordinary objects were wholly eligible.
Framework bootstrap objects commonly mix accessors, symbols, non-default flags,
or one-off wide dictionaries. Compact descriptors had therefore already taken
the low-risk portion of the memory win, while a pure slot representation could
cover only a small final-heap subset.

## Prototype contract

The prototype deliberately preserved the VM's ownership and boundedness rules:

- immutable shapes and values tuples owned by one evaluation;
- binary keys and integer shape identities, never input-derived atoms;
- at most 256 transitions and 32 fields per shape;
- transition metadata stored with existing owner-local prototype metadata so the
  hot `%Execution{}` struct did not gain fields;
- host templates built with shapes disabled, then evaluation-local transitions
  enabled after copy-on-write installation;
- ordinary objects with `internal: nil` only;
- full dictionary fallback for accessors, non-default descriptors, deletion,
  non-binary keys, capacity exhaustion, and unsupported layouts;
- canonical `Heap`, `Properties`, descriptor, enumeration, export, and logical
  memory behavior;
- no ETS, process dictionary, native mutable state, or cross-evaluation shape
  sharing.

`QuickBEAM.VM.ObjectStorage` isolated dictionary and slot layouts. A shaped
object stored `{:slots, shape, values}` in the existing `properties` field, so
all objects did not pay for extra struct fields. Cached transitions reused
immutable key tuples and key-to-slot maps. Guarded lookups returned compact
`{value}` descriptors and exceptional writes materialized a canonical map before
performing their effect.

## Correctness

The experimental branch passed:

- 244 VM tests with three explicit skips;
- all six pinned Test262 interpreter/compiler gates;
- exact step and logical-memory assertions;
- property ordering, accessors, deletion, reflection, export, SSR parity,
  concurrency, and compiler-profile tests;
- focused shape sharing, exceptional fallback, and 256-transition capacity
  tests.

Correctness and boundedness were not the reason for rejection.

## Measurements

All comparisons used the same OTP 29 / ERTS 17.0.2 environment and the existing
reproducible benchmark scripts.

### Retained object fixture

The 5,000-object fixture creates three default fields per object.

| representation | wall median | reductions median | retained VM heap | endpoint process memory |
|---|---:|---:|---:|---:|
| compact property maps | 44.59 ms | 4,908,322 | 2.32 MiB | 9.13 MiB |
| bounded shapes and slots | 42.68 ms | 5,307,243 | 2.01 MiB | 7.28 MiB |

Slots reduced retained VM heap by 13.4% and the wall observation by 4.3%, but
increased deterministic reductions by 8.1%. This synthetic workload gives every
object exactly the same ideal shape and therefore represents an upper-bound use
case rather than SSR behavior.

### Pinned SSR

A 50-sample sequential comparison produced:

| fixture | compact maps | bounded shapes | change | reduction change | endpoint memory change |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 8.37 ms | 8.39 ms | +0.2% | +5.1% | none |
| Vue 3.5.39 | 47.07 ms | 50.30 ms | +6.9% | +4.4% | none |
| Svelte 5.56.4 | 12.30 ms | 12.25 ms | -0.4% | +5.4% | none |

Three additional paired 30-sample Vue runs had compact-map medians of 46.36,
46.68, and 52.39 ms. Shape medians were 50.62, 84.17, and 51.75 ms. Discarding
neither outliers nor unfavorable runs, the shape path was slower and more
variable.

Three five-render `:eprof` repetitions were mixed: median attributed CPU was
470.41 ms for compact maps and 463.10 ms for shapes. That small profiler-only
improvement did not translate into the release-gating endpoint and accompanied
higher reductions. No CPU win is claimed.

## Why it lost

The existing compact map performs one property-map lookup and retains only a
one-tuple around default values. The shape path replaces that with:

- representation dispatch;
- a shape index-map lookup followed by tuple access;
- transition-map admission on new fields;
- values-tuple copying;
- eventual dictionary materialization for mixed objects.

Those costs are amortized in the ideal repeated-shape fixture, but Vue has few
repeated wholly eligible shapes. A dynamic first-use transition policy also
spends work on one-off bootstrap objects before knowing whether a shape will be
reused. The retained reduction was too small to alter SSR endpoint heap classes.

## Decision

Do not merge the runtime shape representation. Compact property maps remain the
canonical release implementation.

A future shape design must avoid speculative transition work. Viable directions
are narrower and semantics-informed:

1. decode-time object-literal plans keyed by immutable function/PC identity;
2. bulk final-shape construction only when bytecode proves the object cannot
   escape during construction;
3. measured admission after repeated complete key sequences, not first-use
   transition creation;
4. hybrid default slots plus an exceptional sidecar, but only if mixed-object
   coverage justifies its permanent object overhead;
5. generated monomorphic property access only after a shape representation wins
   the interpreter-first SSR gate.

Any replacement must again preserve bounded binary identities, owner-local
state, dictionary fallback, exact accounting, Test262, SSR parity, and scheduler
containment. It must improve pinned Vue rather than only a synthetic ideal-shape
fixture.
