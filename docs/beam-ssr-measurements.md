# BEAM VM SSR measurements

These results cover only the pinned, non-streaming fixtures listed below. They
are not browser, DOM, or general framework compatibility claims. Each render
performs one asynchronous `Beam.call` with a fixed 5 ms handler delay. The
single-scheduler fairness and timeout gate is published separately in
[`beam-scheduler-measurements.md`](beam-scheduler-measurements.md).

## Environment

- Git base: `548fec89`
- Working tree at measurement: modified
- Generated: 2026-07-13T22:08:37Z
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
| Preact 10.29.7 | 8.49 ms | 9.47 ms | 3651 | 266.2 KiB | 4.5 MiB | 194939 |
| Vue 3.5.39 | 48.55 ms | 50.4 ms | 11957 | 992.3 KiB | 92.58 MiB | 838301 |
| Svelte 5.56.4 | 12.36 ms | 13.24 ms | 1777 | 397.3 KiB | 12.48 MiB | 204614 |

`VM steps` and `logical memory` are deterministic counters. Endpoint process
memory and reductions are observed once after result conversion; they are not
sampled peaks. Wall time includes process startup, the 5 ms host wait,
rendering, conversion, and reply delivery.

## Concurrent isolated renders

| Fixture | concurrency | renders | throughput | per-render wall median | per-render wall p95 |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | 1 | 30 | 89.0 renders/s | 8.47 ms | 9.33 ms |
| Preact 10.29.7 | 4 | 30 | 270.1 renders/s | 9.79 ms | 10.68 ms |
| Preact 10.29.7 | 8 | 30 | 448.4 renders/s | 10.51 ms | 12.19 ms |
| Vue 3.5.39 | 1 | 30 | 9.3 renders/s | 58.7 ms | 60.37 ms |
| Vue 3.5.39 | 4 | 30 | 19.3 renders/s | 99.46 ms | 125.37 ms |
| Vue 3.5.39 | 8 | 30 | 20.3 renders/s | 182.81 ms | 227.28 ms |
| Svelte 5.56.4 | 1 | 30 | 43.8 renders/s | 14.08 ms | 15.46 ms |
| Svelte 5.56.4 | 4 | 30 | 114.7 renders/s | 18.82 ms | 21.83 ms |
| Svelte 5.56.4 | 8 | 30 | 133.9 renders/s | 29.37 ms | 35.65 ms |

## 100-render isolation and reclamation probe

The Preact fixture was rendered 100 times concurrently with unique request
data and one shared immutable program.

| successful isolated renders | throughput | caller memory delta after GC | process-count delta |
|---:|---:|---:|---:|
| 100/100 | 480.1 renders/s | -941.8 KiB | 0 |

Request-specific IDs were checked in every result. Memory and process deltas
are endpoint observations after explicit caller GC, not operating-system RSS
measurements.

## Resource-limit and cancellation checks

| Fixture | step rejection | memory rejection | timeout | observed timeout wall | handler cancellation after return |
|---|---:|---:|---:|---:|---:|
| Preact 10.29.7 | limit:steps at 3650 | limit:memory_bytes at 133.1 KiB | limit:timeout at 200 ms | 201.19 ms | 34 µs |
| Vue 3.5.39 | limit:steps at 11956 | limit:memory_bytes at 496.1 KiB | limit:timeout at 200 ms | 212.69 ms | 25 µs |
| Svelte 5.56.4 | limit:steps at 1776 | limit:memory_bytes at 198.7 KiB | limit:timeout at 200 ms | 202.65 ms | 24 µs |

Memory rejection uses half the fixture's successful logical allocation.
Timeout uses a non-returning asynchronous handler and verifies that its BEAM
process terminates. Cancellation time is measured from `measure/2` returning
to observation of the handler's `:DOWN` message.
