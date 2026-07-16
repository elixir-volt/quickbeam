# BEAM VM single-scheduler probe

Run with `ERL_FLAGS="+S 1:1"`. The pinned Vue SSR fixture and a periodic BEAM
ticker share one scheduler. The baseline sleeps for the median render wall
time, allowing the same ticker to run without interpreter work.

- Engine: interpreter
- Compiler profile: pure_v1
- Shared program handles: true
- Git base: `8f498a5a`
- Working tree at measurement: modified
- Generated: 2026-07-16T22:01:33Z
- Elixir: 1.20.2
- OTP: 29
- ERTS: 17.0.2
- OS: Linux 7.0.0-27-generic
- Architecture: x86_64-pc-linux-gnu
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Online schedulers: 1
- Vue probe memory limit: 512 MB
- Samples: 30

| workload | wall median | wall p95 | ticker gap median | ticker gap p95 | ticker gap max | ticks median |
|---|---:|---:|---:|---:|---:|---:|
| Vue SSR | 4.91 ms | 5.74 ms | 1.73 ms | 2.03 ms | 2.04 ms | 2 |
| sleep baseline (5 ms target) | 6.0 ms | 6.0 ms | 2.0 ms | 2.01 ms | 2.01 ms | 3 |

Acceptance bound: Vue SSR ticker gap ≤ 75.0 ms.

## Timeout containment

An infinite JavaScript loop was evaluated with a 50 ms outer timeout.

| timeout | wall median | wall p95 | wall max | median overshoot |
|---:|---:|---:|---:|---:|
| 50 ms | 50.99 ms | 51.0 ms | 51.02 ms | 990 µs |

Acceptance bound: timeout p95 ≤ 60.0 ms.
