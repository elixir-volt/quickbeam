# Architecture

QuickBEAM embeds QuickJS-NG inside the BEAM. Each JS runtime is a
GenServer with a dedicated OS thread for the JS engine. The two worlds
communicate through a lock-free message queue — no JSON, no serialization
overhead on the hot path.

## Layers

```
┌──────────────────────────────────────────────────────┐
│  Elixir API  (QuickBEAM, QuickBEAM.Pool)             │
├──────────────────────────────────────────────────────┤
│  GenServer   (QuickBEAM.Runtime)                      │
│  ┌────────────────────────────────────────────────┐  │
│  │  Handlers: user + browser + node + beam        │  │
│  │  Pending calls map, monitors, workers          │  │
│  └────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────┤
│  NIF bridge  (quickbeam.zig → Zigler)                 │
│  ┌────────────────────────────────────────────────┐  │
│  │  Lock-free queue: BEAM → JS thread             │  │
│  │  Direct term passing: no JSON in the data path │  │
│  └────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────┤
│  JS worker thread  (worker.zig)                       │
│  ┌────────────────────────────────────────────────┐  │
│  │  QuickJS-NG runtime + context                  │  │
│  │  Timer heap (setTimeout/setInterval)           │  │
│  │  Pending Beam.call promises                    │  │
│  │  Event loop: drain queue → eval → drain jobs   │  │
│  └────────────────────────────────────────────────┘  │
├──────────────────────────────────────────────────────┤
│  Native globals (Zig)          │  TS polyfills        │
│  ──────────────────────────    │  ────────────────    │
│  Beam.call/callSync/send/self  │  fetch, WebSocket    │
│  Beam.peek (JS_PromiseState)   │  Blob, File, Streams │
│  TextEncoder/Decoder           │  URL, Headers        │
│  atob/btoa                     │  EventTarget, Events │
│  console                       │  Worker              │
│  crypto.getRandomValues        │  BroadcastChannel    │
│  performance.now               │  locks, localStorage │
│  structuredClone               │  Buffer, FormData    │
│  setTimeout/setInterval        │  EventSource, DOM    │
│  DOM (lexbor C)                │  compression, crypto │
├──────────────────────────────────────────────────────┤
│  C libraries                                          │
│  QuickJS-NG (JS engine)  ·  lexbor (HTML/DOM/CSS)     │
└──────────────────────────────────────────────────────┘
```

## Threading model

Each runtime has exactly one OS thread. The BEAM scheduler never touches
the JS heap — all communication goes through a lock-free queue.

```
BEAM scheduler                    JS worker thread
──────────────                    ────────────────
GenServer.call(:eval, code)
  → NIF: enqueue(data, {:eval, ...})
  → returns ref immediately         dequeues {:eval, ...}
                                     JS_Eval(ctx, code)
                                     drain_jobs()  (microtasks)
                                     fire timers
                                     JS→BEAM result via send()
  ← receive {ref, {:ok, value}}
```

`Beam.callSync` works differently — the JS thread parks on a
`ResetEvent` while the BEAM GenServer handles the call message,
executes the handler in a Task, and signals the event with the result.
This lets JS call Elixir synchronously without deadlocking.

`Beam.call` (async) creates a JS Promise and stores resolve/reject
functions keyed by call ID. When the BEAM handler completes, it
enqueues a resolve message. The JS thread picks it up, resolves the
promise, and drains microtasks.

## Data conversion

Values cross the BEAM↔JS boundary without JSON. The Zig layer
(`beam_to_js.zig` / `js_to_beam.zig`) maps types directly:

| BEAM | JS | Notes |
|---|---|---|
| integer | number/BigInt | BigInt for > 2^53 |
| float | number | |
| binary | string | UTF-8 |
| `{:bytes, bin}` | Uint8Array | Raw bytes |
| atom | Symbol | `:foo` ↔ `Symbol("foo")` |
| list | Array | |
| map | Object | String keys |
| pid/ref/port | Opaque wrapper | Round-trips correctly |
| `nil` | null | |
| `:Infinity` / `:NaN` | Infinity / NaN | |

Opaque BEAM terms (PIDs, refs, ports) are wrapped in JS objects that
carry the raw external term format. They can be passed back to
`Beam.send()`, `Beam.monitor()`, etc. and will be decoded back to the
original BEAM term.

## API surfaces

The runtime loads different polyfill sets based on the `:apis` option:

- **`:browser`** (default) — Web APIs backed by OTP: fetch (`:httpc`),
  URL (`:uri_string`), crypto.subtle (`:crypto`), WebSocket (`:gun`),
  Worker (BEAM processes), BroadcastChannel (`:pg`), localStorage (ETS),
  navigator.locks (GenServer), DOM (lexbor), streams, events, etc.

- **`:node`** — Node.js compat: process, path, fs, os, child_process.
  `process.env` is a live Proxy over `System.get_env/put_env`.

- **`[:browser, :node]`** — both.

- **`false`** — bare QuickJS engine, no polyfills. `Beam.call`/`callSync`
  still work (they're native Zig).

Regardless of the API surface, the `Beam` object is always available with
the full bridge + utilities (version, sleep, hash, peek, etc.).

## The `Beam` object

`Beam` is installed at the Zig level (`beam_call.zig`) with native
C functions for the hot path (`call`, `callSync`, `send`, `self`,
`onMessage`, `peek`). Extended APIs are added by `beam-api.ts` which
calls back into Elixir handlers registered in `@beam_handlers`.

The design principle: anything that benefits from BEAM primitives is
exposed on `Beam`, not shimmed in JS. This includes:

- **Process primitives**: `monitor`, `demonitor`, `link`, `unlink`,
  `register`, `whereis`, `spawn`
- **Cluster**: `nodes`, `rpc`
- **Introspection**: `systemInfo`, `processInfo`, `peek`
- **Crypto**: `password.hash`/`verify` (PBKDF2 via `:crypto`)
- **Utilities**: `hash` (`:erlang.phash2`), `which`
  (`System.find_executable`), `escapeHTML`, `randomUUIDv7`,
  `semver` (Elixir `Version`)

## Handler dispatch

When JS calls `Beam.call("db.query", sql)`:

1. **Zig** (`beam_call.zig`): Creates a Promise, stores resolve/reject
   by call ID, sends `{:beam_call, id, "db.query", [sql]}` to the
   owning GenServer.

2. **GenServer** (`runtime.ex` `handle_info`): Looks up the handler in
   the merged handlers map. Spawns a Task to run it (so slow handlers
   don't block the GenServer).

3. **Task**: Calls the user function, sends the result back via
   `Native.resolve_call_term(resource, id, result)`.

4. **NIF** → **JS thread**: Enqueues a resolve message. Worker dequeues
   it, resolves the Promise, drains microtasks.

`Beam.callSync` skips the Promise — the JS thread blocks on a
`SyncCallSlot` (a mutex + condition variable) while the BEAM side
executes the handler and signals completion.

## DOM

Every runtime has a live DOM tree backed by lexbor (C library). The
bridge in `dom.zig` exposes `document.createElement`,
`querySelector`, `innerHTML`, etc. as native JS functions that
manipulate the C DOM directly.

Elixir can read the same DOM tree through `dom_find/2`, `dom_text/2`,
etc. — these go through the NIF queue and return Floki-compatible
`{tag, attrs, children}` tuples. No JS execution, no HTML re-parsing.

This is the key SSR primitive: JS renders into the DOM, Elixir reads
it out as a tree.

## TypeScript toolchain

OXC (Rust NIFs via `rustler_precompiled`) provides:
- **Transform**: Strip types from TS/TSX → JS
- **Bundle**: Resolve imports, topological sort, wrap in IIFE
- **Minify**: Compress + mangle

The `:script` option on `QuickBEAM.start` auto-detects imports and
bundles everything at startup. TypeScript files are transformed.
`node_modules/` imports are resolved from disk.

The built-in polyfills (`priv/ts/*.ts`) are compiled at Elixir compile
time by the `Compiler` module inside `runtime.ex`:
- Standalone files are wrapped in IIFEs
- `web-apis.ts` is a barrel file that gets bundled with its imports
- The compiled JS is stored in module attributes (`@browser_js`, etc.)

## Pool

`QuickBEAM.Pool` wraps `NimblePool` for concurrent request handling.
Each checkout gets a runtime, each checkin resets it and re-runs the
init function. This gives a clean JS context per request while
amortizing startup cost.

## Supervision

Runtimes are GenServers — they fit naturally into OTP supervision
trees. The `:script` option re-evaluates on restart, giving automatic
crash recovery with state reload.

The application supervisor starts:
- `:pg` group for BroadcastChannel (distributed pub/sub)
- `LockManager` GenServer for `navigator.locks`
- `Storage` ETS table for `localStorage`
