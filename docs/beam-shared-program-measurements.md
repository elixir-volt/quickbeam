# BEAM VM SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay.
The single-scheduler fairness and timeout gate is published separately in [`beam-scheduler-measurements.md`](beam-scheduler-measurements.md).

## Environment

- Engine: interpreter
- Compiler profile: pure_v1
- Compiler regions: false
- Shared program handles: true
- Git base: `8f498a5a`
- Working tree at measurement: modified
- Generated: 2026-07-16T21:50:19Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- OS: Linux 7.0.0-27-generic
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Logical schedulers: 32
- Mix environment: `bench`
- Samples per fixture: 100 after 10 warmups
- Concurrency levels: 1, 4, 8

## Sequential isolated renders

| Fixture | wall median | wall p95 | VM steps | logical memory | endpoint process memory | reductions median |
|---|---:|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 7.01 ms | 8.0 ms | 3651 | 266.2 KiB | 257.7 KiB | 137493 |
| Vue 3.5.39 | 11.01 ms | 12.4 ms | 11957 | 991.9 KiB | 673.3 KiB | 630442 |
| Svelte 5.56.4 | 6.99 ms | 7.23 ms | 1777 | 397.1 KiB | 673.3 KiB | 124663 |

`VM steps` and `logical memory` are deterministic counters. Endpoint process
memory and reductions are observed once after result conversion; they are not
sampled peaks. Wall time includes process startup, the 5 ms host wait,
rendering, conversion, and reply delivery.


## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 100 | 142.3 renders/s | 6.98 ms | 7.56 ms |
| Preact 10.29.7 | 4 | 100 | 547.9 renders/s | 7.09 ms | 8.07 ms |
| Preact 10.29.7 | 8 | 100 | 1068.4 renders/s | 7.09 ms | 7.86 ms |
| Vue 3.5.39 | 1 | 100 | 90.0 renders/s | 10.98 ms | 12.16 ms |
| Vue 3.5.39 | 4 | 100 | 361.5 renders/s | 10.95 ms | 12.2 ms |
| Vue 3.5.39 | 8 | 100 | 684.7 renders/s | 11.07 ms | 12.01 ms |
| Svelte 5.56.4 | 1 | 100 | 141.3 renders/s | 6.97 ms | 7.9 ms |
| Svelte 5.56.4 | 4 | 100 | 562.0 renders/s | 6.98 ms | 7.78 ms |
| Svelte 5.56.4 | 8 | 100 | 1072.1 renders/s | 6.99 ms | 7.96 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 6240.6 renders/s | -12.5 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 200.3 ms | 36 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 495.9 KiB | limit:timeout at 200 ms | 201.08 ms | 5 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.6 KiB | limit:timeout at 200 ms | 200.68 ms | 19 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
