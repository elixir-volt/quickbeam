# Changelog

## 0.6.1

### Changed

- Bump `npm` dependency to `~> 0.4.2`

## 0.6.0

### Added

- **DOM prototype chain** — full hierarchy: `Node` → `Element` → `HTMLElement`/`SVGElement`/`MathMLElement`, plus `Document`, `DocumentFragment`, `Text`, `Comment`. Constructor globals on `globalThis` enable `instanceof` checks
- **`Symbol.toStringTag`** — `Object.prototype.toString.call(el)` returns `[object HTMLDivElement]` with 40+ HTML tag mappings
- **`MutationObserver` no-op stub** — `observe()`, `disconnect()`, `takeRecords()` for SSR compatibility
- **`document.nodeType`** (returns 9) and **`document.nodeName`** (returns `"#document"`) getters
- **Node object identity** — same DOM node always returns the same JS wrapper (`el.parentNode === el.parentNode`, `document.body === document.body`). Uses `DocumentData.node_map` with `gc_mark` to prevent premature collection
- **163 WPT-ported tests** — `Node`, `Element`, `ChildNode`, `Document` APIs adapted from Web Platform Tests

### Changed

- **`tagName`/`nodeName` return uppercase** for HTML elements (spec compliant). SVG/MathML elements preserve original case
- **`textContent = ""`** removes all children instead of creating an empty text node
- **Default `max_stack_size` bumped to 4 MB** (from 1 MB) — Vue mount path needs ~2 MB+
- `innerHTML` setter uses shared `remove_all_children` path with node map eviction

### Fixed

- **Node identity cache leak** — `innerHTML=` and `textContent=` now recursively evict replaced subtrees from the node map, preventing stale pointers and unbounded map growth
- **`JS_DupValue` leak on OOM** — map put failure now frees the duplicated ref
- Removed unused `qb_node_set_user`/`qb_node_get_user` C bridge functions, `NodePtr` type alias, and empty `element_finalizer`

## 0.5.0

### Added

- **`QuickBEAM.ContextPool`** — pool of N runtime threads (default: `System.schedulers_online()`) with round-robin context distribution
- **`QuickBEAM.Context`** — lightweight GenServer owning a single `JSContext` on a shared pool thread. Full API: eval, call, Beam.call/callSync, DOM, messaging, handlers, supervision. Linked to the calling process for automatic cleanup (ideal for LiveView `mount`)
- **Granular API groups** — contexts can load individual API groups (`:fetch`, `:websocket`, `:worker`, `:channel`, `:eventsource`, `:url`, `:crypto`, `:compression`, `:buffer`, `:dom`, `:console`, `:storage`, `:locks`) instead of the full `:browser` bundle. Dependencies auto-resolve
- **Per-context memory tracking** (QuickJS patch) — `js_malloc`/`js_free`/`js_realloc` track `ctx->malloc_size`. `Context.memory_usage/1` returns `:context_malloc_size`
- **Per-context memory limits** (QuickJS patch) — `Context.start_link(memory_limit: 512_000)` enforces per-context allocation limit via `ctx->malloc_limit`
- **Per-context reduction limits** (QuickJS patch) — `Context.start_link(max_reductions: 100_000)` interrupts long-running evals after an opcode budget. Count resets per-operation; context stays usable
- **Precompiled bytecodes** — polyfill JS compiled to QuickJS bytecodes once, cached in `persistent_term`. Context creation ~3.2x faster via `JS_EvalFunction`
- **NIF operations for globals** — `get_global`, `list_globals`, `snapshot_globals`, `delete_globals` use `JS_GetPropertyStr`/`JS_GetOwnPropertyNames`/`JS_DeleteProperty` instead of eval round-trips
- **`QuickBEAM.JS` module** — shared polyfill compilation with granular API group system, compile-time barrel bundles, OXC toolchain delegations (`imports`, `postwalk`, `patch_string`)
- 39 new tests (17 functional + 22 stress): 1K-context scale, 200-task thundering herd, memory leak checks, isolation, error recovery, handler contention, burst messaging, resource limits

### Changed

- Worker protocol uses integer IDs instead of PIDs, with `Beam.call`/`callSync` handlers instead of `Beam.send` with tagged arrays
- `eval_with_vars` uses `delete_globals` NIF instead of `try/finally/delete` JS hack
- `globals/2` and `get_global/2` use NIF operations instead of eval
- `Beam.callSync` drain interval reduced from 10ms to 1ms with drain callback for context pool promise resolution

### Fixed

- `LocksTest` — removed redundant `start_supervised!(QuickBEAM.LockManager)` (already started by application supervisor)
- Worker spawn/terminate race conditions with integer ID-based tracking

### Performance

| | Runtime (1:1 thread) | Context (pooled) |
|---|---|---|
| Per instance | ~530 KB heap + 2.5 MB stack | 58–429 KB (no thread) |
| OS threads at 10K | 10,000 | 4 (configurable) |
| Total RAM at 10K | ~30 GB | 570 MB–4.2 GB |

Per-context memory by API surface: bare 58 KB, beam 71 KB, beam+url 108 KB, beam+fetch 231 KB, full browser 429 KB.

## 0.4.0

### Added

- **MessageChannel / MessagePort** — paired ports with `structuredClone` + `queueMicrotask` async delivery, `onmessage` auto-start per spec
- **FormData** — full CRUD + iteration, Blob→File wrapping, multipart/form-data encoding in `fetch`
- **Performance Timeline** — `performance.mark()`, `performance.measure()`, `getEntries()`, `getEntriesByType()`, `getEntriesByName()`, `clearMarks()`, `clearMeasures()`, `toJSON()`, `timeOrigin`
- **`child_process.execSync`** — backed by `System.cmd`, with `cwd`, `env`, `timeout`, `maxBuffer` options
- **`child_process.exec`** — async callback variant
- **`Beam.peek(promise)`** — read a promise's value synchronously via native `JS_PromiseState`. Returns the promise itself if pending. `Beam.peek.status(promise)` returns `'fulfilled'`, `'rejected'`, or `'pending'`
- **`Beam.password.hash/verify`** — PBKDF2-SHA256 password hashing with PHC-format output, constant-time comparison
- **Beam utility extensions** — `Beam.sleep()`, `Beam.sleepSync()`, `Beam.hash()`, `Beam.escapeHTML()`, `Beam.which()`, `Beam.randomUUIDv7()`, `Beam.deepEquals()`, `Beam.version`, `Beam.semver.satisfies()`, `Beam.semver.order()`
- **Beam OTP extensions** — `Beam.nodes()`, `Beam.rpc()`, `Beam.spawn()`, `Beam.register()`, `Beam.whereis()`, `Beam.link()`, `Beam.unlink()`, `Beam.systemInfo()`, `Beam.processInfo()`
- **Precompiled NIF support** via `zigler_precompiled` — end users don't need Zig installed
- **JavaScript API reference** and **Architecture overview** on HexDocs

### Fixed

- **`set_global`/`eval` with `:vars` silently failing on Linux** — `JS_SetPropertyStr` requires null-terminated C strings but `gpa.dupe` produced non-null-terminated Zig slices. Fixed with `gpa.dupeZ` + `[:0]const u8`
- **Worker init hang** — exposing PerformanceEntry/Mark/Measure on `globalThis` exceeded QuickJS internal threshold (~126 globals). Classes are now returned from API methods only

### Improved

- Expanded WPT test coverage for Blob, TextDecoder, and URL
- Test suite reorganized into `core/`, `web_apis/`, `dom/`, `node/`, `toolchain/`, `wpt/` subdirectories
- CI: all four jobs passing (test, UBSan, ASAN, clang-tidy)

## 0.3.1

### Added

- **`eval/3` `:vars` option** — pass variables into JS code as temporary globals, cleaned up automatically via `try`/`finally` (even on errors or timeouts)
- **`set_global/3`** — set JS globals from Elixir using native BEAM→JS conversion, counterpart to `get_global/2`

## 0.3.0

### Changed

- **OXC upgraded to 0.5.0** — adds `jsx_factory`, `jsx_fragment`, and `import_source` options for JSX transform and bundle
- **Replaced examples** — removed `content_pipeline` and `plugin_sandbox`, added:
  - `rule_engine` — user-defined business rules in sandboxed runtimes (`apis: false`, memory limits, timeouts, hot reload, handlers as controlled API)
  - `live_dashboard` — Workers (BEAM processes) + BroadcastChannel (`:pg`) for parallel metrics computation with crash recovery
  - `ssr` now uses JSX syntax via OXC classic mode

### Added

- **Node.js compatibility APIs** — `process`, `path`, `fs`, `os` backed by OTP
- **`:apis` option** for `QuickBEAM.start/1` — controls which API surface to load:
  - `:browser` — Web APIs (default, same as before)
  - `:node` — Node.js compat
  - `[:browser, :node]` — both
  - `false` — bare QuickJS, no polyfills
- **Extended DOM API** backed by lexbor C library:
  - `document.createDocumentFragment()`, `document.createComment()`
  - `document.createElementNS()` for SVG/MathML/namespaced elements
  - `document.getElementsByClassName()`, `document.getElementsByTagName()`
  - `element.insertBefore()`, `element.replaceChild()`, `element.cloneNode()`
  - `element.contains()`, `element.remove()`, `element.before()`, `element.after()`
  - `element.prepend()`, `element.append()`, `element.replaceWith()`
  - `element.matches()`, `element.closest()`
  - `element.getElementsByClassName()`, `element.getElementsByTagName()`
  - `element.lastChild`, `element.previousSibling`, `element.nodeType`, `element.nodeName`, `element.nodeValue`, `element.parentElement`
  - `element.className` is now read-write
  - `DocumentFragment` correctly moves children in `appendChild`/`insertBefore`
- **`element.classList`** — full `DOMTokenList` implementation (`add`, `remove`, `toggle`, `contains`, `replace`, `forEach`, `item`, `length`, `value`, `Symbol.iterator`)
- **`element.style`** — `CSSStyleDeclaration` backed by lexbor CSS parser (`getPropertyValue`, `setProperty`, `removeProperty`, `getPropertyPriority`, `cssText`, `length`, `item`, camelCase property access via Proxy)
- **`getComputedStyle()`** — returns inline style declaration (no cascade/layout)
- **`addEventListener`/`removeEventListener`/`dispatchEvent`** on elements and `document`, with `once`, `stopImmediatePropagation`, `handleEvent` object listeners
- **`CustomEvent`** with `detail` property

### Improved

- Import extraction uses `OXC.imports/2` NIF instead of full AST parsing — faster bundling and script loading

### Fixed

- Locks tests failing due to redundant `LockManager` start (already started by application supervisor)
- CI cache keys now hash Zig sources, fixing stale native builds
- ASAN CI job correctly finds beam binary path

### Infrastructure

- `clang-tidy` static analysis for `lexbor_bridge.c` in CI (`clang-analyzer-*`, `bugprone-*`, `portability-*`)

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
