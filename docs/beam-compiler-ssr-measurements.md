# BEAM compiler SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay. The
single-scheduler fairness and timeout gate is published separately in
[`beam-compiler-scheduler-measurements.md`](beam-compiler-scheduler-measurements.md).

## Environment

- Engine: compiler
- Git base: `85d7a677`
- Working tree at measurement: modified
- Generated: 2026-07-15T23:02:53Z
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
| Preact 10.29.7 | 9.83 ms | 10.44 ms | 3651 | 266.2 KiB | 4.5 MiB | 336743 |
| Vue 3.5.39 | 72.42 ms | 79.31 ms | 11957 | 992.3 KiB | 77.15 MiB | 3990571 |
| Svelte 5.56.4 | 17.05 ms | 20.15 ms | 1777 | 397.3 KiB | 15.61 MiB | 735344 |

`VM steps` and `logical memory` are deterministic counters. Endpoint process
memory and reductions are observed once after result conversion; they are not
sampled peaks. Wall time includes process startup, the 5 ms host wait,
rendering, conversion, and reply delivery.

## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 30 | 78.3 renders/s | 10.16 ms | 10.61 ms |
| Preact 10.29.7 | 4 | 30 | 242.8 renders/s | 10.82 ms | 13.05 ms |
| Preact 10.29.7 | 8 | 30 | 403.1 renders/s | 12.56 ms | 14.29 ms |
| Vue 3.5.39 | 1 | 30 | 7.4 renders/s | 82.03 ms | 88.88 ms |
| Vue 3.5.39 | 4 | 30 | 16.7 renders/s | 136.04 ms | 156.63 ms |
| Vue 3.5.39 | 8 | 30 | 18.0 renders/s | 232.63 ms | 289.2 ms |
| Svelte 5.56.4 | 1 | 30 | 36.2 renders/s | 18.3 ms | 20.34 ms |
| Svelte 5.56.4 | 4 | 30 | 98.5 renders/s | 23.94 ms | 29.09 ms |
| Svelte 5.56.4 | 8 | 30 | 115.8 renders/s | 35.31 ms | 45.59 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 407.4 renders/s | -941.8 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 201.08 ms | 28 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 496.1 KiB | limit:timeout at 200 ms | 212.87 ms | 16 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.7 KiB | limit:timeout at 200 ms | 203.77 ms | 24 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
