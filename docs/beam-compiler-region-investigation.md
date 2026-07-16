# Bounded compiler region investigation

This investigation tests whether bounded region compilation can overcome the
whole-function admission bottleneck without weakening the compiler contract.
It does **not** enable a production compiler tier. `QuickBEAM.VM.eval/2` still
defaults to the interpreter, and `compiler_regions: false` is the compiler
default.

## Coverage probes

The reproducible static inventory in
[`beam-compiler-region-probe.md`](beam-compiler-region-probe.md) found
86.0–89.9% scalar-regionizable instructions across the pinned fixtures, but the
32 largest static regions covered only 2.9–6.1% of fixture bytecode. The opt-in
dynamic Space-Saving probe in
[`beam-compiler-region-hotspots.md`](beam-compiler-region-hotspots.md) estimated
fixed-pool supported lower bounds of 85.2% for Preact, 46.9% for Vue, and 77.7%
for Svelte. Those estimates count supported instructions in sampled 64-PC
windows; they are opportunity bounds, not generated-code coverage or speedup
predictions.

## Bounded executor experiment

The opt-in `compiler_regions: true` path preserves the existing safety bounds:

- binary program/function/entry/profile admission and artifact identities;
- three encounters before admission;
- at most `capacity * 8`, and never more than 256, shared observation entries;
- a stable admitted set capped at half the module pool (16 regions at capacity 32),
  preventing admitted regions alone from churning the pool;
- at most 256 owner-local decisions and the existing fixed 32-module pool;
- exact lease validation, soft-purge-only eviction, and before-instruction deopt;
- one straight-line entry block of at most 32 operations;
- runtime tuple updates at early boundaries, avoiding unsafe generated
  `setelement` optimization;
- exact interpreter parity for result, steps, logical allocation, limits, and
  cancellation.

The executor currently enters regions only at function PC 0. It deoptimizes
before a terminal branch, unsupported instruction, suspension, or the next
uncompiled block. It does not recursively execute generated regions.

## Measured result: reject for release

The pinned 10-sample report is
[`beam-compiler-region-ssr-measurements.md`](beam-compiler-region-ssr-measurements.md).
Warm sequential medians were:

| Fixture | scalar compiler without regions | bounded regions | generated step coverage |
|---|---:|---:|---:|
| Preact 10.29.7 | 9.66 ms | 17.01 ms | 2.4% |
| Vue 3.5.39 | 64.45 ms | 112.70 ms | 0.7% |
| Svelte 5.56.4 | 15.45 ms | 15.97 ms | 0.0% |

The stable 16-region cap prevents region-driven module-pool churn, but a simple
three-encounter policy admits early regions rather than the strongest dynamic
heavy hitters. Vue entered generated code only eight times and executed 79 of
11,957 steps in generated code. Preact entered 23 small regions and
immediately deoptimized each time. Boundary, lease, frame-reconstruction, and
admission costs therefore remain larger than the generated work.

A warm three-render `:eprof` comparison attributed 371.04 ms of CPU with regions
versus 337.28 ms without them, a 10.0% increase. Deterministic artifact and
admission serialization (`:erlang.term_to_binary/2`) rose from 13.55 ms across
144 calls to 18.22 ms across 831 calls, while synchronous `gen:do_call/4` rose
from 0.21 ms to 0.84 ms. The region profile made 639 admission calls and 1,035
region-frame attempts. This identifies repeated admission identity work and
small-region transitions as measured CPU costs after pool churn is bounded.

The experiment therefore fails the SSR release gate and remains explicitly
quarantined. A future design should not expand opcode coverage or admit more
regions until it can select materially longer hot traces, amortize entry/deopt
cost, and demonstrate lower Vue wall time with the same resource and scheduler
contracts.
