# Changelog

## Unreleased

### Added

- **Node.js compatibility APIs** — `process`, `path`, `fs`, `os` backed by OTP
- **`:apis` option** for `QuickBEAM.start/1` — controls which API surface to load:
  - `:browser` — Web APIs (default, same as before)
  - `:node` — Node.js compat
  - `[:browser, :node]` — both
  - `false` — bare QuickJS, no polyfills

## 0.2.0

### Breaking

- **Unified `Beam` namespace** — `beam.call` → `Beam.call`, `beam.callSync` → `Beam.callSync`, `beam.send` → `Beam.send`, `beam.self` → `Beam.self`, `Process.onMessage` → `Beam.onMessage`, `Process.monitor` → `Beam.monitor`, `Process.demonitor` → `Beam.demonitor`

### Added

- Auto-bundle imports and TypeScript in `:script` option — `.ts`/`.tsx` files are transformed via OXC, files with `import` statements are bundled into a single IIFE with relative paths and bare specifiers resolved from `node_modules/`
- `QuickBEAM.JS.bundle_file/2` for programmatic bundling of entry files with all dependencies
- npm dependency management via `mix npm.install`

### Performance

- Atom cache for QuickJS↔BEAM boundary — pre-created JS strings for common atoms (`nil`, `true`, `false`, `ok`, `error`, etc.) avoid repeated allocations on every conversion
- Direct promise result inspection via `JS_PromiseState`/`JS_PromiseResult` — removes temporary globals, eval overhead, and a per-iteration string leak
- Lazy proxy objects for BEAM→JS map conversion — maps with >4 entries are wrapped in a `BeamMapProxy` backed by the original BEAM term, converting properties only on access
- Zero-copy string optimizations — map key conversion uses `JS_NewAtomLen`/`JS_AtomToCStringLen` directly, removing intermediate allocations and the 256-byte key length limit
- Worker `postMessage` uses direct `beam.send` instead of routing through `beam.call` handlers
- Non-blocking NIFs — `eval`/`call`/`compile` return immediately with a ref, results delivered asynchronously via `enif_send`. Dirty IO schedulers are no longer blocked.

### Fixed

- **Segfault on concurrent runtime init** — QuickJS class IDs for `BeamMapProxy` and DOM were allocated under separate mutexes, causing ID collisions when multiple runtimes initialized concurrently. All custom class IDs are now allocated under a single shared mutex.
- Deadlock on runtime shutdown — `beam.callSync` now uses a `shutting_down` flag with timed polling so the worker thread exits cleanly when `GenServer.stop` is called while a sync call is pending
- Locks and BroadcastChannel tests failing with `--no-start`
- Test suite hanging under parallel execution due to missing `:telemetry` dependency

## 0.1.0

Initial release.

### JavaScript Engine

- QuickJS-NG embedded via Zig NIFs — no system JS runtime needed
- Runtimes are GenServers with full OTP supervision support
- Persistent state across `eval/2` and `call/3` calls
- ES module loading with `load_module/3`
- Bytecode compilation and loading for fast cloning
- CPU timeout with `JS_SetInterruptHandler`
- Configurable memory limit and stack size

### BEAM Integration

- `Beam.call` / `Beam.callSync` — JS calls Elixir handler functions
- `Beam.send` / `Beam.self` — JS sends messages to BEAM processes
- `Beam.onMessage` / `Beam.monitor` / `Beam.demonitor`
- Direct BEAM term conversion (no JSON serialization)
- Runtime pools via NimblePool

### Web APIs

Standard browser APIs backed by BEAM/Zig primitives:

- `fetch`, `Request`, `Response`, `Headers` — `:httpc`
- `document`, `querySelector`, `createElement` — lexbor native DOM
- `URL`, `URLSearchParams` — `:uri_string`
- `crypto.subtle` (digest, sign, verify, encrypt, decrypt, generateKey, deriveBits) — `:crypto`
- `crypto.getRandomValues`, `randomUUID` — Zig `std.crypto.random`
- `TextEncoder`, `TextDecoder` — native Zig UTF-8
- `TextEncoderStream`, `TextDecoderStream`
- `ReadableStream`, `WritableStream`, `TransformStream` with `pipeThrough`/`pipeTo`
- `setTimeout`, `setInterval`, `clearTimeout`, `clearInterval` — Zig timer heap
- `console.log/warn/error/debug/trace/assert/time/timeEnd/count/dir/group` — Erlang Logger
- `CompressionStream`, `DecompressionStream` — `:zlib`
- `Buffer` (encode, decode, byteLength) — `Base`, `:unicode`
- `EventTarget`, `Event`, `CustomEvent`, `MessageEvent`, `CloseEvent`, `ErrorEvent`
- `AbortController`, `AbortSignal`
- `Blob`, `File`
- `BroadcastChannel` — `:pg` (distributed across cluster)
- `WebSocket` — `:gun`
- `Worker` — BEAM process-backed JS workers with `postMessage`
- `navigator.locks` (Web Locks API) — GenServer with monitor-based cleanup
- `localStorage` — ETS (shared across runtimes)
- `EventSource` (Server-Sent Events) — `:httpc` streaming
- `DOMException`
- `atob`, `btoa` — Zig base64
- `structuredClone` — QuickJS serialization
- `queueMicrotask` — `JS_EnqueueJob`
- `performance.now` — nanosecond precision

### DOM

- Native DOM via lexbor C library
- Elixir-side DOM queries: `dom_find/2`, `dom_find_all/2`, `dom_text/2`, `dom_attr/3`, `dom_html/1`
- Returns Floki-compatible `{tag, attrs, children}` tuples

### TypeScript Toolchain

- `QuickBEAM.JS` — parse, transform, minify, bundle via OXC Rust NIFs
- `QuickBEAM.eval_ts/3` — evaluate TypeScript directly
- TypeScript sources compiled at build time via OXC (no Node.js/Bun required)
