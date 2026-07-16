# BEAM VM SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay. The
single-scheduler fairness and timeout gate is published separately in
[`beam-scheduler-measurements.md`](beam-scheduler-measurements.md).

## Environment

- Engine: interpreter
- Git base: `041fd186`
- Working tree at measurement: modified
- Generated: 2026-07-16T08:17:54Z
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
| Preact 10.29.7 | 8.22 ms | 9.09 ms | 3651 | 266.2 KiB | 4.5 MiB | 135016 |
| Vue 3.5.39 | 49.21 ms | 50.88 ms | 11957 | 991.9 KiB | 77.15 MiB | 694328 |
| Svelte 5.56.4 | 15.15 ms | 18.05 ms | 1777 | 397.1 KiB | 15.61 MiB | 134963 |

`VM steps` and `logical memory` are deterministic counters. Endpoint process
memory and reductions are observed once after result conversion; they are not
sampled peaks. Wall time includes process startup, the 5 ms host wait,
rendering, conversion, and reply delivery.

## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 30 | 87.7 renders/s | 8.52 ms | 9.38 ms |
| Preact 10.29.7 | 4 | 30 | 284.5 renders/s | 9.11 ms | 11.4 ms |
| Preact 10.29.7 | 8 | 30 | 466.9 renders/s | 9.8 ms | 11.67 ms |
| Vue 3.5.39 | 1 | 30 | 8.5 renders/s | 62.79 ms | 72.85 ms |
| Vue 3.5.39 | 4 | 30 | 17.5 renders/s | 117.98 ms | 135.12 ms |
| Vue 3.5.39 | 8 | 30 | 18.1 renders/s | 204.55 ms | 269.75 ms |
| Svelte 5.56.4 | 1 | 30 | 38.3 renders/s | 15.9 ms | 17.14 ms |
| Svelte 5.56.4 | 4 | 30 | 105.3 renders/s | 21.34 ms | 26.59 ms |
| Svelte 5.56.4 | 8 | 30 | 124.2 renders/s | 32.42 ms | 41.3 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 534.1 renders/s | -941.8 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 200.7 ms | 22 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 495.9 KiB | limit:timeout at 200 ms | 214.46 ms | 27 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.6 KiB | limit:timeout at 200 ms | 202.89 ms | 31 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
