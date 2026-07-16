# Object-literal allocation investigation

This report evaluates semantics-aware one-shot construction of proven
non-escaping object-literal prefixes. The prototype is preserved on branch
`object-literal-plans` at commit `4f17cb7f` and is rejected for the release path.

## Prototype contract

The decoder attached bounded plans to immutable functions by function-local
program counter. A plan required at least four statically named default fields
and accepted only straight-line stack, scalar, local, and selected value/object
operations. Calls, control flow, computed definitions, methods, accessors,
spread, and any operation capable of consuming the protected object terminated
analysis. Nested eligible literals had independent plans.

At runtime the implementation:

- reserved the exact owner-local object ID at the original `object` instruction;
- charged logical object memory at that instruction;
- retained a fixed tuple builder on the explicit frame stack;
- charged each first property definition at its original `define_field`;
- preserved duplicate-key last-value and first-insertion ordering;
- allowed nested literals while preventing the incomplete outer object from
  becoming an ordinary JavaScript value;
- constructed the compact property map once and inserted the object into the
  owner heap after the final planned field;
- preserved IDs when nested allocations occurred between object creation and
  materialization;
- used no process dictionary, ETS, dynamic atoms, native mutable state, or
  cross-evaluation cache.

The physical heap write was delayed, but deterministic steps, logical allocation,
exceptions, and step-limit rejection remained at canonical instruction
boundaries.

## Static opportunity

The final conservative analyzer found:

| fixture | object opcodes | planned prefixes | planned fields | field counts |
|---|---:|---:|---:|---|
| Preact 10.29.7 | 23 | 2 | 16 | 6, 10 |
| Vue 3.5.39 | 111 | 13 | 99 | five 4-field, two 5-field, two 7-field, two 10-field, one 11-field, one 24-field |
| Svelte 5.56.4 | 20 | 3 | 19 | 4, 6, 9 |

Vue `:eprof` observed 80 planned allocations and 575 planned fields over five
renders: 16 literals and 115 fields per render. The same profile performed about
948 ordinary heap allocations and 1,028 property definitions per render. The
optimization therefore reached roughly 1.7% of allocations and 11.2% of property
definitions.

Broader variants were also tested. Allowing resumable calls and default methods
raised Vue's static inventory to 32 prefixes and 171 fields, but retaining
builders across invocation boundaries increased endpoint latency and variance.
That variant was discarded before the final conservative measurement.

## Ideal repeated-literal fixture

A controlled fixture creates 5,000 objects with the same four default fields.
Two pinned-core 100-sample runs per representation produced stable results:

| representation | wall median | reductions median | endpoint process memory | steps | logical memory |
|---|---:|---:|---:|---:|---:|
| canonical incremental maps | 51.95 ms | 5,677,983 | 7.28 MiB | 150,022 | 5.62 MiB |
| one-shot literal plans | 46.69 ms | 5,194,294 | 9.13 MiB | 150,022 | 5.62 MiB |

One-shot construction reduced wall time by 10.1% and reductions by 8.5% in its
ideal workload. The higher endpoint heap class illustrates why endpoint process
memory is not equivalent to retained term size or peak RSS.

## Pinned Vue gate

Three pinned-core, single-scheduler runs used 200 samples after ten warmups. Run
order was alternated:

| run | canonical median | planned median | canonical p95 | planned p95 |
|---:|---:|---:|---:|---:|
| 1 | 53.81 ms | 49.44 ms | 74.21 ms | 53.50 ms |
| 2 | 46.19 ms | 51.58 ms | 50.63 ms | 56.96 ms |
| 3 | 46.07 ms | 49.43 ms | 48.01 ms | 57.18 ms |

The first run reflected machine warmup. In both subsequent orderings the planned
path was 7–12% slower. Median-of-run medians was 46.19 ms for canonical maps and
49.44 ms for plans, a 7.1% regression. Median reductions improved only about
0.3%, steps and logical memory were exact, and endpoint process-memory classes
were unchanged.

Five-render `:eprof` totals were effectively neutral: approximately 450 ms for
both implementations. Avoiding a small number of persistent map updates did not
amortize tuple-builder updates, list accumulation, reversal, and final `Map.new/1`
on Vue's short and mostly cold literal prefixes.

The experimental scheduler probe remained within the existing bounds, but that
does not override failure of the Vue latency gate.

## Correctness

The experimental branch passed:

- 246 VM tests with three explicit skips;
- all six pinned Test262 interpreter/compiler gates;
- duplicate keys, nested literals, caught exceptions, exact resource parity, and
  exact step-limit rejection;
- existing Preact, Vue, and Svelte parity, async, cancellation, and concurrency
  tests;
- warnings-as-errors and focused new-module Credo checks.

Correctness was not the reason for rejection.

## Decision

Do not merge object-literal builders. Compact incremental property maps remain
the canonical implementation.

The experiment establishes an important boundary: one-shot construction is
valuable when a repeated literal has at least four fields, but current pinned SSR
executes too few eligible literals to offset builder and finalization overhead.
Expanding across calls improves static coverage while worsening the release
endpoint.

Further object optimization should begin with exact call-site attribution of the
remaining `maps:put/3` and object-heap updates. Another speculative allocation
tier should not be added unless dynamic measurements identify a substantially
larger hot population than either bounded shapes or object-literal plans reached.
