# Bun Vendor Lock-in APIs → QuickBEAM `Beam` Object

Analysis of Bun-specific APIs that have no Web/Node standard equivalent,
and which ones could be exposed via the `Beam` object backed by Erlang/OTP.

## Current `Beam` API

```
Beam.call(handler, ...args)       — async call to Elixir handler
Beam.callSync(handler, ...args)   — sync call to Elixir handler
Beam.send(pid, message)           — fire-and-forget to BEAM process
Beam.self()                       — owning GenServer PID
Beam.onMessage(callback)          — receive BEAM messages
Beam.monitor(pid, callback)       — monitor BEAM process
Beam.demonitor(ref)               — cancel monitor
```

## Bun Vendor APIs — Categorized

### ✅ Already covered by QuickBEAM (different surface)

| Bun API | QuickBEAM equivalent |
|---|---|
| `Bun.serve()` | Not applicable (BEAM handles HTTP) |
| `Bun.file()` / `Bun.write()` | `fs.readFileSync` / `fs.writeFileSync` (Node compat) |
| `Bun.spawn()` / `Bun.spawnSync()` | `child_process.execSync` (Node compat) |
| `Bun.gzipSync()` / `Bun.gunzipSync()` / `Bun.deflateSync()` / `Bun.inflateSync()` | `compression.compress()` / `compression.decompress()` (`:zlib`) |
| `Bun.CryptoHasher` | `crypto.subtle.digest()` (`:crypto`) |
| `Bun.password.hash()` / `verify()` | Could use `:crypto` but not yet exposed |
| `Bun.env` | `process.env` (Node compat, backed by `System.get_env`) |
| `Bun.Transpiler` | `QuickBEAM.JS.transform/2` (OXC, Elixir-side) |
| `Bun.build` (bundler) | `QuickBEAM.JS.bundle/1` (OXC, Elixir-side) |

### 🎯 Good candidates for `Beam.*` — OTP has natural backends

| Bun API | Proposed `Beam.*` | OTP backend | Notes |
|---|---|---|---|
| `Bun.sleep(ms)` | `Beam.sleep(ms)` | `Promise` + timer already exists via `setTimeout`, but `Beam.sleep` is cleaner sugar | Trivial — `new Promise(r => setTimeout(r, ms))` |
| `Bun.sleepSync(ms)` | `Beam.sleepSync(ms)` | Block JS thread via NIF/`:timer.sleep` | Useful for scripts |
| `Bun.nanoseconds()` | `Beam.nanoseconds()` | `:erlang.monotonic_time(:nanosecond)` | Already have `performance.now()` (ns precision) but integer ns is handy |
| `Bun.version` | `Beam.version` | `Application.spec(:quickbeam, :vsn)` | Runtime identification |
| `Bun.hash()` | `Beam.hash(data, algo?)` | `:crypto.hash/2` or `:erlang.phash2/2` | Fast non-crypto hash — `:erlang.phash2` is perfect |
| `Bun.deepEquals(a, b)` | `Beam.deepEquals(a, b)` | Already have `structuredClone` semantics, but direct BEAM-side comparison avoids JS overhead | Could use NIF comparison of terms |
| `Bun.escapeHTML(str)` | `Beam.escapeHTML(str)` | OTP has `:xmerl_lib.export_text/1` (escapes `<>&` but misses `"` and `'`). Full 5-char escape needs a small wrapper or Zig. | SSR use case |
| `Bun.peek(promise)` | `Beam.peek(promise)` | QuickJS `JS_PromiseState` introspection | Read promise state synchronously — useful for perf |
| `Bun.which(bin)` | `Beam.which(bin)` | `System.find_executable/1` | |
| `Bun.resolveSync(specifier, from)` | `Beam.resolveSync(specifier, from)` | OXC resolver / custom resolution | Module resolution |
| `Bun.randomUUIDv7()` | `Beam.randomUUIDv7()` | Pure Elixir UUIDv7 (timestamp + `:crypto.strong_rand_bytes`) | Monotonic, sortable — very useful for DBs |
| `Bun.semver` | `Beam.semver` | `Version` module (Elixir stdlib) | `.satisfies()`, `.order()` |

### 🔥 Unique to BEAM — things Bun *can't* do

These are **anti-vendor-lock-in** — they make `Beam.*` the _reason_ to choose QuickBEAM, not a trap.

| Proposed API | OTP backend | Description |
|---|---|---|
| `Beam.spawn(fn)` | `Task.start/1` behind the scenes | Spawn a new JS runtime as a BEAM process — true parallelism |
| `Beam.nodes()` | `:erlang.nodes/0` | List connected BEAM nodes — distributed JS |
| `Beam.rpc(node, handler, args)` | `:erpc.call/4` | Call a handler on a remote node |
| `Beam.register(name)` | `Process.register/2` | Register the runtime under a name for discovery |
| `Beam.whereis(name)` | `Process.whereis/1` | Look up a registered runtime |
| `Beam.link(pid)` / `Beam.unlink(pid)` | `Process.link/1` | Bidirectional crash propagation |
| `Beam.systemInfo()` | `:erlang.system_info/1` | Schedulers, memory, process count, atom count |
| `Beam.processInfo()` | `Process.info/1` on self | Reductions, memory, message queue length |

### 🤷 Bun APIs with limited value for QuickBEAM

| Bun API | Why skip |
|---|---|
| `Bun.serve()` | BEAM handles HTTP natively (Bandit/Cowboy) |
| `Bun.listen()` / `Bun.connect()` (TCP) | `:gen_tcp` from Elixir side |
| `Bun.udpSocket()` | `:gen_udp` from Elixir side |
| `Bun.sql` / `bun:sqlite` | Ecto/ETS from Elixir side |
| `Bun.redis` | Redix from Elixir side |
| `bun:ffi` | NIFs from Elixir side |
| `Bun.plugin()` | Module loading handled by OXC bundler |
| `Bun.Glob` | Path.wildcard / :filelib from Elixir |
| `Bun.color()` | Very niche |
| `Bun.stringWidth()` | Very niche |
| `Bun.openInEditor()` | Desktop-only, niche |
| `Bun.mmap()` | Low-level, Elixir-side concern |
| `Bun.gc()` | QuickJS GC is different model |
| `Bun.indexOfLine()` | Too niche |
| `Bun.ArrayBufferSink` | Streams API covers this |
| `HTMLRewriter` | QuickBEAM has native DOM — use that instead |
| `Bun.markdown()` | Niche, Elixir has Earmark |
| `Bun.TOML.parse()` | Niche |
| `Bun.$` (shell) | `child_process.execSync` covers it |
| `Bun.FileSystemRouter` | Framework-level, not runtime |
| `Bun.Cookie` / `Bun.CookieMap` | Framework-level |

## Recommended Priority

### Tier 1 — Low effort, high value
1. **`Beam.version`** — trivial property, good for identification
2. **`Beam.sleep(ms)`** — syntactic sugar over setTimeout, matches Bun
3. **`Beam.hash(data)`** — `:erlang.phash2` for fast non-crypto hashing
4. **`Beam.which(bin)`** — `System.find_executable/1`, one-liner
5. **`Beam.escapeHTML(str)`** — SSR use case, can be Zig-fast

### Tier 2 — Medium effort, unique to BEAM
6. **`Beam.nodes()`** — distributed JS is a killer feature
7. **`Beam.rpc(node, handler, args)`** — remote handler calls
8. **`Beam.spawn(fn)`** — parallel JS via BEAM processes
9. **`Beam.systemInfo()`** — introspection into the BEAM VM
10. **`Beam.randomUUIDv7()`** — monotonic UUIDs

### Tier 3 — Nice to have
11. `Beam.peek(promise)` — perf optimization
12. `Beam.deepEquals(a, b)` — testing utility
13. `Beam.semver.satisfies()` — version checking
14. `Beam.sleepSync(ms)` — blocking sleep
15. `Beam.nanoseconds()` — integer timestamp
