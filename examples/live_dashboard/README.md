# Live Dashboard

Workers and BroadcastChannel — features backed by BEAM primitives that no other JS runtime has.

```
                        ┌─────────────────────┐
                        │   Elixir Supervisor  │
                        └──────────┬──────────┘
                                   │
                        ┌──────────▼──────────┐
                        │    Coordinator JS    │◄──── QuickBEAM.call("getDashboard")
                        │  (BEAM GenServer)    │
                        └──┬───────┬───────┬──┘
              new Worker() │       │       │ new Worker()
                    ┌──────▼──┐ ┌──▼────┐ ┌▼────────┐
                    │CPU Worker│ │Memory │ │Requests │
                    │(BEAM pid)│ │Worker │ │ Worker  │
                    └────┬─────┘ └──┬────┘ └───┬─────┘
                         │          │          │
                         ▼          ▼          ▼
               BroadcastChannel("dashboard")  ← backed by :pg
                         │
                         ▼
                    Coordinator receives aggregated metrics
```

## What's happening

1. **Coordinator** — a supervised QuickBEAM runtime that spawns 3 Workers
2. **Workers** — each `new Worker(code)` spawns a real BEAM process running its own QuickJS runtime
3. **BroadcastChannel** — Workers publish metrics to a named channel backed by Erlang's `:pg` process groups
4. **Coordinator listens** — receives metrics from all Workers via the same BroadcastChannel
5. **Elixir reads** — calls `getDashboard()` to get the aggregated state

Workers are not threads or an event loop — they are separate BEAM processes with preemptive scheduling. BroadcastChannel doesn't use shared memory — it uses `:pg`, which works across distributed BEAM nodes.

## Run

```sh
mix deps.get
mix run run.exs
```

```
╔══════════════════════════════════════════════════════╗
║         QuickBEAM Live Dashboard Example             ║
║  Workers = BEAM processes  ·  BroadcastChannel = :pg ║
╚══════════════════════════════════════════════════════╝

── Snapshot 1 ─────────────────────────────────────
  CPU    47.3%  load: [2.41, 1.87, 1.23]  cores: 8
  MEM    [████████████░░░░░░░░] 61.2%  (10030/16384 MB)
  REQ    1847 rps  latency: 23.4ms  errors: 1.7%  conns: 183
  updated: 2025-03-12T10:00:01.234Z
```

## Test

```sh
mix test
```

## Key features demonstrated

- **Workers as BEAM processes** — `new Worker(code)` spawns an OTP process, not a thread
- **BroadcastChannel as :pg** — pub/sub across JS runtimes using Erlang process groups
- **Crash recovery** — kill the coordinator, the supervisor restarts it, Workers are re-created
- **Request/response pattern** — coordinator sends `postMessage("collect")`, workers respond with metrics
- **Cross-runtime messaging** — Workers broadcast results that the coordinator aggregates
