# BEAM scalar compiler SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay. The
single-scheduler fairness and timeout gate is published separately in
[`beam-compiler-scalar-scheduler-measurements.md`](beam-compiler-scalar-scheduler-measurements.md).

## Environment

- Engine: compiler
- Compiler profile: scalar_v1
- Git base: `bc1aaf50`
- Working tree at measurement: modified
- Generated: 2026-07-16T09:53:54Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- OS: Linux 7.0.0-27-generic
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Logical schedulers: 32
- Mix environment: `bench`
- Samples per fixture: 30 after 3 warmups
- Concurrency levels: 1, 4, 8

## Sequential isolated renders

| Fixture | wall median | wall p95 | VM steps | logical memory | endpoint process memory | reductions median |
|---|---:|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 9.66 ms | 11.15 ms | 3651 | 266.2 KiB | 7.28 MiB | 221871 |
| Vue 3.5.39 | 64.45 ms | 69.78 ms | 11957 | 991.9 KiB | 77.15 MiB | 1275315 |
| Svelte 5.56.4 | 15.45 ms | 19.98 ms | 1777 | 397.1 KiB | 15.61 MiB | 271145 |

`VM steps` and `logical memory` are deterministic counters. Endpoint process
memory and reductions are observed once after result conversion; they are not
sampled peaks. Wall time includes process startup, the 5 ms host wait,
rendering, conversion, and reply delivery.

## Compiler execution counters

These fixed-key counters are captured from the evaluation owner. Generated
steps, entries, deoptimizations, invocation actions, and re-entries describe
execution; compile/cache/skip fields remain module-pool lifecycle observations.

| Fixture | frame attempts | skipped frames | decisions C/H/S | generated steps | step coverage | entries | deopts | invocation actions | re-entries | leading deopt opcodes | hot interpreted opcodes |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---|
| Preact 10.29.7 | 50 | 49 | 0/1/15 | 0 | 0.0% | 1 | 1 | 0 | 0 | `check_define_var`=1 | `if_false8`=269, `get_loc8`=234, `push_atom_value`=234, `dup`=230, `drop`=193, `get_var`=182, `get_arg0`=180, `strict_eq`=109 |
| Vue 3.5.39 | 306 | 296 | 0/3/90 | 126 | 1.1% | 10 | 4 | 6 | 2 | `return_undef`=2, `check_define_var`=1, `get_var`=1 | `swap`=936, `dup`=664, `get_loc_check`=598, `if_false8`=582, `check_define_var`=480, `get_var`=468, `get_arg0`=464, `set_loc_uninitialized`=403 |
| Svelte 5.56.4 | 34 | 33 | 0/1/22 | 0 | 0.0% | 1 | 1 | 0 | 0 | `check_define_var`=1 | `check_define_var`=202, `fclosure8`=154, `define_func`=117, `define_var`=85, `set_loc_uninitialized`=74, `get_var`=65, `get_loc_check`=64, `put_var_init`=63 |


## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 30 | 73.6 renders/s | 10.2 ms | 11.55 ms |
| Preact 10.29.7 | 4 | 30 | 239.6 renders/s | 10.98 ms | 12.28 ms |
| Preact 10.29.7 | 8 | 30 | 395.3 renders/s | 12.62 ms | 14.06 ms |
| Vue 3.5.39 | 1 | 30 | 7.6 renders/s | 70.51 ms | 88.52 ms |
| Vue 3.5.39 | 4 | 30 | 16.4 renders/s | 126.54 ms | 151.01 ms |
| Vue 3.5.39 | 8 | 30 | 18.3 renders/s | 219.96 ms | 264.18 ms |
| Svelte 5.56.4 | 1 | 30 | 37.3 renders/s | 16.67 ms | 21.02 ms |
| Svelte 5.56.4 | 4 | 30 | 95.3 renders/s | 23.99 ms | 27.05 ms |
| Svelte 5.56.4 | 8 | 30 | 116.7 renders/s | 33.25 ms | 41.72 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 468.6 renders/s | -929.3 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 200.88 ms | 34 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 495.9 KiB | limit:timeout at 200 ms | 213.9 ms | 37 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.6 KiB | limit:timeout at 200 ms | 202.46 ms | 30 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
