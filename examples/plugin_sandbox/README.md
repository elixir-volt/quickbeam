# Plugin sandbox

Multi-tenant user code execution with isolated JS runtimes.

Each plugin is a QuickBEAM runtime with its own memory limit and a
capability-based handler system — no filesystem, no network, unless
explicitly granted.

## What's happening

```
Plugin "pricing"            Plugin "transform"          Plugin "hog"
┌────────────────────┐      ┌────────────────────┐      ┌────────────────────┐
│ QuickJS runtime    │      │ QuickJS runtime    │      │ QuickJS runtime    │
│ capabilities: [kv] │      │ capabilities: []   │      │ memory: 2 MB max   │
│ handlers:          │      │ handlers: (none)   │      │                    │
│   kv.get → ETS     │      │ pure computation   │      │ OOM → runtime dies │
│   kv.set → ETS     │      │ only               │      │ supervisor restarts│
└────────────────────┘      └────────────────────┘      └────────────────────┘
```

## Run

```sh
mix deps.get
mix run run.exs
```

```
Gold tier: $100 → $80 (20% off)
Transform: %{"reversed" => "MAEBkciuQ olleH", "upper" => "HELLO QUICKBEAM", "words" => 2}

Loading memory hog plugin (2 MB limit)...
Memory hog stopped: %QuickBEAM.JSError{message: "out of memory", ...}

Loading infinite loop plugin (1s timeout)...
Infinite loop stopped: interrupted

Loaded plugins: [:pricing, :hog, :transform, :looper]
```

## Test

```sh
mix test
```

## Key features demonstrated

- **Isolation** — each plugin gets its own JS heap; globals don't leak between runtimes
- **Memory limits** — runaway allocations hit the wall and get an OOM error
- **Timeouts** — infinite loops are interrupted after the deadline
- **Capabilities** — plugins declare what they need: `:kv`, `:http`, `:log`
- **No `fetch` by default** — without the `:http` capability, `fetch` is `undefined`
- **Dynamic loading** — plugins are started/stopped via `DynamicSupervisor`
- **Per-plugin KV** — each plugin's ETS table is namespaced by ID
