# BEAM scalar compiler single-scheduler probe

Run with `ERL_FLAGS="+S 1:1"`. The pinned Vue SSR fixture and a periodic BEAM
ticker share one scheduler. The baseline sleeps for the median render wall
time, allowing the same ticker to run without compiler work.

- Engine: compiler
- Compiler profile: scalar_v1
- Git base: `bc1aaf50`
- Working tree at measurement: modified
- Generated: 2026-07-16T09:54:48Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- OS: Linux 7.0.0-27-generic
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Online schedulers: 1
- Vue probe memory limit: 512 MB
- Samples: 10

| workload | wall median | wall p95 | ticker gap median | ticker gap p95 | ticker gap max | ticks median |
|---|---:|---:|---:|---:|---:|---:|
| Vue SSR | 177.57 ms | 205.3 ms | 2.0 ms | 8.53 ms | 35.52 ms | 65 |
| sleep baseline (178 ms target) | 178.95 ms | 178.98 ms | 2.0 ms | 2.01 ms | 3.8 ms | 89 |

Acceptance bound: Vue SSR ticker gap ≤ 75.0 ms.

## Timeout containment

An infinite JavaScript loop was evaluated with a 50 ms outer timeout.

| timeout | wall median | wall p95 | wall max | median overshoot |
|---:|---:|---:|---:|---:|
| 50 ms | 50.98 ms | 51.1 ms | 51.1 ms | 983 µs |

Acceptance bound: timeout p95 ≤ 60.0 ms.
