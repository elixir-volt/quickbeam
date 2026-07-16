# Bounded region compiler SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay.
The region experiment has no scheduler-gate claim because it fails the SSR latency gate.

## Environment

- Engine: compiler
- Compiler profile: scalar_v1
- Compiler regions: true
- Git base: `0a332b81`
- Working tree at measurement: modified
- Generated: 2026-07-16T13:26:26Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- OS: Linux 7.0.0-27-generic
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Logical schedulers: 32
- Mix environment: `bench`
- Samples per fixture: 10 after 3 warmups
- Concurrency levels: 1

## Sequential isolated renders

| Fixture | wall median | wall p95 | VM steps | logical memory | endpoint process memory | reductions median |
|---|---:|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 17.01 ms | 24.87 ms | 3651 | 266.2 KiB | 4.5 MiB | 295627 |
| Vue 3.5.39 | 112.7 ms | 129.6 ms | 11957 | 991.9 KiB | 77.15 MiB | 1416407 |
| Svelte 5.56.4 | 15.97 ms | 17.85 ms | 1777 | 397.1 KiB | 15.61 MiB | 273454 |

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
| Preact 10.29.7 | 73 | 50 | 0/10/16 | 86 | 2.4% | 23 | 23 | 0 | 23 | `get_length`=7, `if_false8`=7, `get_field`=4, `get_var`=2, `check_define_var`=1, `push_atom_value`=1, `to_object`=1 | `if_false8`=269, `get_loc8`=234, `push_atom_value`=234, `dup`=223, `drop`=193, `get_var`=179, `get_arg0`=161, `strict_eq`=109 |
| Vue 3.5.39 | 306 | 298 | 0/1/92 | 79 | 0.7% | 8 | 2 | 6 | 2 | `return_undef`=2 | `swap`=936, `dup`=664, `get_loc_check`=598, `if_false8`=582, `check_define_var`=480, `get_var`=468, `get_arg0`=464, `set_loc_uninitialized`=450 |
| Svelte 5.56.4 | 34 | 34 | 0/0/23 | 0 | 0.0% | 0 | 0 | 0 | 0 |  | `check_define_var`=202, `fclosure8`=154, `define_func`=117, `define_var`=85, `set_loc_uninitialized`=74, `get_var`=65, `get_loc_check`=64, `put_var_init`=63 |


## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 10 | 52.1 renders/s | 14.44 ms | 17.68 ms |
| Vue 3.5.39 | 1 | 10 | 4.7 renders/s | 124.4 ms | 153.57 ms |
| Svelte 5.56.4 | 1 | 10 | 33.6 renders/s | 19.09 ms | 22.0 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 192.4 renders/s | -929.3 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 201.19 ms | 42 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 495.9 KiB | limit:timeout at 200 ms | 223.41 ms | 25 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.6 KiB | limit:timeout at 200 ms | 206.26 ms | 64 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
