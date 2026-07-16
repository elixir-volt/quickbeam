# BEAM compiler SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay. The
single-scheduler fairness and timeout gate is published separately in
[`beam-compiler-scheduler-measurements.md`](beam-compiler-scheduler-measurements.md).

## Environment

- Engine: compiler
- Git base: `041fd186`
- Working tree at measurement: modified
- Generated: 2026-07-16T08:24:26Z
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
| Preact 10.29.7 | 10.4 ms | 11.1 ms | 3651 | 266.2 KiB | 7.28 MiB | 275998 |
| Vue 3.5.39 | 75.77 ms | 86.55 ms | 11957 | 991.9 KiB | 92.58 MiB | 3842362 |
| Svelte 5.56.4 | 16.19 ms | 18.67 ms | 1777 | 397.1 KiB | 12.48 MiB | 653386 |

`VM steps` and `logical memory` are deterministic counters. Endpoint process
memory and reductions are observed once after result conversion; they are not
sampled peaks. Wall time includes process startup, the 5 ms host wait,
rendering, conversion, and reply delivery.

## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 30 | 69.5 renders/s | 10.7 ms | 11.87 ms |
| Preact 10.29.7 | 4 | 30 | 249.6 renders/s | 10.88 ms | 12.18 ms |
| Preact 10.29.7 | 8 | 30 | 392.9 renders/s | 12.6 ms | 14.88 ms |
| Vue 3.5.39 | 1 | 30 | 7.3 renders/s | 84.18 ms | 91.52 ms |
| Vue 3.5.39 | 4 | 30 | 15.1 renders/s | 146.39 ms | 192.97 ms |
| Vue 3.5.39 | 8 | 30 | 18.0 renders/s | 237.52 ms | 252.46 ms |
| Svelte 5.56.4 | 1 | 30 | 38.7 renders/s | 17.25 ms | 19.27 ms |
| Svelte 5.56.4 | 4 | 30 | 98.6 renders/s | 23.65 ms | 28.03 ms |
| Svelte 5.56.4 | 8 | 30 | 121.4 renders/s | 35.74 ms | 44.39 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 447.2 renders/s | -941.8 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 201.1 ms | 22 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 495.9 KiB | limit:timeout at 200 ms | 212.76 ms | 25 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.6 KiB | limit:timeout at 200 ms | 202.47 ms | 24 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
