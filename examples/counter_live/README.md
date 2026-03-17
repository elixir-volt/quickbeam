# Counter + LiveView

The simplest QuickBEAM example: a counter where each LiveView session gets its own lightweight JS context from a shared pool.

## Architecture

```
  Browser A        Browser B        Browser C
     │                │                │
     ▼                ▼                ▼
  ┌────────────────────────────────────────┐
  │         Phoenix LiveView               │
  │  mount() → Context.start_link(pool:)   │
  │  handle_event → Context.call("inc")    │
  └────────────────┬───────────────────────┘
                   │
  ┌────────────────▼───────────────────────┐
  │        QuickBEAM.ContextPool (2 threads)│
  │                                         │
  │  Thread 1 (JSRuntime)                   │
  │  ├── Context A (~58 KB) {count: 7}     │
  │  └── Context C (~58 KB) {count: 0}     │
  │                                         │
  │  Thread 2 (JSRuntime)                   │
  │  └── Context B (~58 KB) {count: -3}    │
  └─────────────────────────────────────────┘
```

## How it works

1. **ContextPool** — 2 runtime threads are shared across all sessions. Each thread can host hundreds of contexts.
2. **Context per session** — `mount/3` creates a ~58 KB JS context linked to the LiveView process. When the user disconnects, the context is automatically cleaned up.
3. **No dedicated OS thread** — unlike a full `QuickBEAM.start()` runtime (~2 MB), contexts share a thread. This makes it practical to run thousands of concurrent sessions.
4. **`apis: false`** — the counter needs no Web APIs, so we skip all polyfills. The context is bare QuickJS (~58 KB vs ~429 KB with browser APIs).
5. **State isolation** — each context has its own `count`. Browser A incrementing doesn't affect Browser B.

## Run

```sh
mix deps.get
mix run run.exs
```

Open http://localhost:4000 in multiple tabs — each has an independent counter.

## Test

```sh
mix test
```

## Key features demonstrated

- **ContextPool + LiveView** — the "1 context per session" pattern
- **~58 KB per user** — lightweight enough for thousands of concurrent connections
- **Automatic cleanup** — context is linked to LiveView process, dies with it
- **State isolation** — each session has independent JS state
- **`apis: false`** — minimal memory footprint when you don't need Web APIs
