# QuickBEAM

JavaScript runtime for the BEAM — Web APIs backed by OTP, native DOM,
and a built-in TypeScript toolchain.

JS runtimes are GenServers. They live in supervision trees, send and
receive messages, and call into Erlang/OTP libraries — all without
leaving the BEAM.

## Installation

```elixir
def deps do
  [{:quickbeam, "~> 0.4.0"}]
end
```

Requires Zig 0.15+ (installed automatically by Zigler, or use system Zig).

## Quick start

```elixir
{:ok, rt} = QuickBEAM.start()
{:ok, 3} = QuickBEAM.eval(rt, "1 + 2")
{:ok, "HELLO"} = QuickBEAM.eval(rt, "'hello'.toUpperCase()")

# State persists across calls
QuickBEAM.eval(rt, "function greet(name) { return 'hi ' + name }")
{:ok, "hi world"} = QuickBEAM.call(rt, "greet", ["world"])

QuickBEAM.stop(rt)
```

## BEAM integration

JS can call Elixir functions and access OTP libraries:

```elixir
{:ok, rt} = QuickBEAM.start(handlers: %{
  "db.query" => fn [sql] -> MyRepo.query!(sql).rows end,
  "cache.get" => fn [key] -> Cachex.get!(:app, key) end,
})

{:ok, rows} = QuickBEAM.eval(rt, """
  const rows = await Beam.call("db.query", "SELECT * FROM users LIMIT 5");
  rows.map(r => r.name);
""")
```

JS can also send messages to any BEAM process:

```javascript
// Get the runtime's own PID
const self = Beam.self();

// Send to any PID
Beam.send(somePid, {type: "update", data: result});

// Receive BEAM messages
Beam.onMessage((msg) => {
  console.log("got:", msg);
});

// Monitor BEAM processes
const ref = Beam.monitor(pid, (reason) => {
  console.log("process died:", reason);
});
Beam.demonitor(ref);
```

## Supervision

Runtimes and context pools are OTP children with crash recovery:

```elixir
children = [
  {QuickBEAM,
   name: :renderer,
   id: :renderer,
   script: "priv/js/app.js",
   handlers: %{
     "db.query" => fn [sql, params] -> Repo.query!(sql, params).rows end,
   }},
  {QuickBEAM, name: :worker, id: :worker},

  # Context pool for high-concurrency use cases
  {QuickBEAM.ContextPool, name: MyApp.JSPool, size: 4},
]

Supervisor.start_link(children, strategy: :one_for_one)

{:ok, html} = QuickBEAM.call(:renderer, "render", [%{page: "home"}])
```

The `:script` option loads a JS file at startup. If the runtime crashes,
the supervisor restarts it with a fresh context and re-evaluates the script.

Individual `Context` processes are typically started dynamically (e.g.
from a LiveView `mount`) and linked to the connection process.

## Context Pool

For high-concurrency scenarios (thousands of connections), use
`ContextPool` instead of individual runtimes. Many lightweight JS
contexts share a small number of runtime threads:

```elixir
# Start a pool with N runtime threads (defaults to scheduler count)
{:ok, pool} = QuickBEAM.ContextPool.start_link(name: MyApp.JSPool, size: 4)

# Each context is a GenServer with its own JS global scope
{:ok, ctx} = QuickBEAM.Context.start_link(pool: MyApp.JSPool)
{:ok, 3} = QuickBEAM.Context.eval(ctx, "1 + 2")
{:ok, "HELLO"} = QuickBEAM.Context.eval(ctx, "'hello'.toUpperCase()")
QuickBEAM.Context.stop(ctx)
```

Contexts support the full API — `eval`, `call`, `Beam.call`/`callSync`,
DOM, messaging, browser/node APIs, handlers, and supervision:

```elixir
# In a Phoenix LiveView
def mount(_params, _session, socket) do
  {:ok, ctx} = QuickBEAM.Context.start_link(
    pool: MyApp.JSPool,
    handlers: %{"db.query" => &MyApp.query/1}
  )
  {:ok, assign(socket, js: ctx)}
end

```

The context is linked to the LiveView process — it terminates and
cleans up automatically when the connection closes. No explicit
`terminate` callback needed.

Memory per context depends on which APIs are loaded: ~55 KB bare,
~65 KB with Beam API, ~375 KB with full browser APIs. All share
a small fixed number of OS threads instead of one per runtime.

## API surfaces

QuickBEAM can load browser APIs, Node.js APIs, or both:

```elixir
# Browser APIs only (default)
QuickBEAM.start(apis: [:browser])

# Node.js compatibility
QuickBEAM.start(apis: [:node])

# Both
QuickBEAM.start(apis: [:browser, :node])

# Bare QuickJS engine — no polyfills
QuickBEAM.start(apis: false)
```

## Node.js compatibility

Like Bun, QuickBEAM implements core Node.js APIs. BEAM-specific
extensions live in the `Beam` namespace.

```elixir
{:ok, rt} = QuickBEAM.start(apis: [:node])

QuickBEAM.eval(rt, """
  const data = fs.readFileSync('/etc/hosts', 'utf8');
  const lines = data.split('\\n').length;
  lines
""")
# => {:ok, 12}
```

| Module | Coverage |
|---|---|
| `process` | `env`, `cwd()`, `platform`, `arch`, `pid`, `argv`, `version`, `nextTick`, `hrtime`, `stdout`, `stderr` |
| `path` | `join`, `resolve`, `basename`, `dirname`, `extname`, `parse`, `format`, `relative`, `normalize`, `isAbsolute`, `sep`, `delimiter` |
| `fs` | `readFileSync`, `writeFileSync`, `appendFileSync`, `existsSync`, `mkdirSync`, `readdirSync`, `statSync`, `lstatSync`, `unlinkSync`, `renameSync`, `rmSync`, `copyFileSync`, `realpathSync`, `readFile`, `writeFile` |
| `os` | `platform()`, `arch()`, `type()`, `hostname()`, `homedir()`, `tmpdir()`, `cpus()`, `totalmem()`, `freemem()`, `uptime()`, `EOL`, `endianness()` |

`process.env` is a live Proxy — reads and writes go to `System.get_env` / `System.put_env`.

## Resource limits

```elixir
{:ok, rt} = QuickBEAM.start(
  memory_limit: 10 * 1024 * 1024,  # 10 MB heap
  max_stack_size: 512 * 1024        # 512 KB call stack
)
```

## Introspection

```elixir
# List user-defined globals (excludes builtins)
{:ok, ["myVar", "myFunc"]} = QuickBEAM.globals(rt, user_only: true)

# Get any global's value
{:ok, 42} = QuickBEAM.get_global(rt, "myVar")

# Runtime diagnostics
QuickBEAM.info(rt)
# %{handlers: ["db.query"], memory: %{...}, global_count: 87}
```

## DOM

Every runtime has a live DOM tree backed by [lexbor](https://github.com/lexbor/lexbor) (the C library
behind PHP 8.4's DOM extension and Elixir's `fast_html`). JS gets a full `document` global:

```javascript
document.body.innerHTML = '<ul><li class="item">One</li><li class="item">Two</li></ul>';
const items = document.querySelectorAll("li.item");
items[0].textContent; // "One"
```

Elixir can read the DOM directly — no JS execution, no re-parsing:

```elixir
{:ok, rt} = QuickBEAM.start()
QuickBEAM.eval(rt, ~s[document.body.innerHTML = '<h1 class="title">Hello</h1>'])

# Returns Floki-compatible {tag, attrs, children} tuples
{:ok, {"h1", [{"class", "title"}], ["Hello"]}} = QuickBEAM.dom_find(rt, "h1")

# Batch queries
{:ok, items} = QuickBEAM.dom_find_all(rt, "li")

# Extract text and attributes
{:ok, "Hello"} = QuickBEAM.dom_text(rt, "h1")
{:ok, "/about"} = QuickBEAM.dom_attr(rt, "a", "href")

# Serialize back to HTML
{:ok, html} = QuickBEAM.dom_html(rt)
```

## Web APIs

Standard browser APIs backed by BEAM primitives, not JS polyfills:

| JS API | BEAM backend |
|---|---|
| `fetch`, `Request`, `Response`, `Headers` | `:httpc` |
| `document`, `querySelector`, `createElement` | lexbor (native C DOM) |
| `URL`, `URLSearchParams` | `:uri_string` |
| `EventSource` (SSE) | `:httpc` streaming |
| `WebSocket` | `:gun` |
| `Worker` | BEAM process per worker |
| `BroadcastChannel` | `:pg` (distributed) |
| `navigator.locks` | GenServer + monitors |
| `localStorage` | ETS |
| `crypto.subtle` | `:crypto` |
| `crypto.getRandomValues`, `randomUUID` | Zig `std.crypto.random` |
| `ReadableStream`, `WritableStream`, `TransformStream` | Pure TS with `pipeThrough`/`pipeTo` |
| `TextEncoder`, `TextDecoder` | Native Zig (UTF-8) |
| `TextEncoderStream`, `TextDecoderStream` | Stream + Zig encoding |
| `CompressionStream`, `DecompressionStream` | `:zlib` |
| `Buffer` | `Base`, `:unicode` |
| `EventTarget`, `Event`, `CustomEvent` | Pure TS |
| `AbortController`, `AbortSignal` | Pure TS |
| `Blob`, `File` | Pure TS |
| `DOMException` | Pure TS |
| `setTimeout`, `setInterval` | Timer heap in worker thread |
| `console` (log, warn, error, debug, time, group, …) | Erlang Logger |
| `atob`, `btoa` | Native Zig |
| `performance.now` | Nanosecond precision |
| `structuredClone` | QuickJS serialization |
| `queueMicrotask` | `JS_EnqueueJob` |

## Data conversion

No JSON in the data path. JS values map directly to BEAM terms:

| JS | Elixir |
|---|---|
| `number` (integer) | `integer` |
| `number` (float) | `float` |
| `string` | `String.t()` |
| `boolean` | `boolean` |
| `null` | `nil` |
| `undefined` | `nil` |
| `Array` | `list` |
| `Object` | `map` (string keys) |
| `Uint8Array` | `binary` |
| `Symbol("name")` | `:name` (atom) |
| `Infinity` / `NaN` | `:Infinity` / `:NaN` |
| PID / Ref / Port | Opaque JS object (round-trips) |

## TypeScript

Type definitions for the BEAM-specific JS API:

```jsonc
// tsconfig.json
{
  "compilerOptions": {
    "types": ["./path/to/quickbeam.d.ts"]
  }
}
```

The `.d.ts` file covers the `Beam` bridge API, opaque BEAM terms
(`BeamPid`, `BeamRef`, `BeamPort`), and the `compression` helper.
Standard Web APIs are typed by TypeScript's `lib.dom.d.ts`.

## TypeScript toolchain

QuickBEAM includes a built-in TypeScript toolchain via [OXC](https://oxc.rs)
Rust NIFs — no Node.js or Bun required:

```elixir
# Evaluate TypeScript directly
{:ok, rt} = QuickBEAM.start()
QuickBEAM.eval_ts(rt, "const x: number = 40 + 2; x")
# => {:ok, 42}

# Transform, minify, bundle — available as QuickBEAM.JS.*
{:ok, js} = QuickBEAM.JS.transform("const x: number = 1", "file.ts")
{:ok, min} = QuickBEAM.JS.minify("const x = 1 + 2;", "file.js")

# Bundle multiple modules into a single IIFE
files = [
  {"utils.ts", "export function add(a: number, b: number) { return a + b }"},
  {"main.ts", "import { add } from './utils'\nconsole.log(add(1, 2))"}
]
{:ok, bundle} = QuickBEAM.JS.bundle(files)
```

## npm packages

QuickBEAM ships with a built-in npm client — no Node.js required.

```sh
mix npm.install sanitize-html
```

The `:script` option auto-resolves imports. Point it at a TypeScript file
that imports npm packages, and QuickBEAM bundles everything at startup:

```elixir
# priv/js/app.ts
import sanitize from 'sanitize-html'

Beam.onMessage((html: string) => {
  Beam.callSync("done", sanitize(html))
})
```

```elixir
{QuickBEAM, name: :sanitizer, script: "priv/js/app.ts", handlers: %{...}}
```

No build step, no webpack, no esbuild. TypeScript is stripped, imports
are resolved from `node_modules/`, and everything is bundled into a
single script via OXC — all at runtime startup.

You can also bundle from disk programmatically:

```elixir
{:ok, js} = QuickBEAM.JS.bundle_file("src/main.ts")
```

## Performance

vs QuickJSEx 0.3.1 (Rust/Rustler, JSON serialization):

| Benchmark | Speedup |
|---|---|
| Function call — small map | **2.5x faster** |
| Function call — large data | **4.1x faster** |
| Concurrent JS execution | **1.35x faster** |
| `Beam.callSync` (JS→BEAM) | 5 μs overhead (unique to QuickBEAM) |
| Startup | ~600 μs (parity) |

Context pool vs individual runtimes at scale:

| | Runtime (1:1 thread) | Context (pooled) |
|---|---|---|
| JS heap per instance | ~530 KB | ~375 KB (full) / ~55 KB (bare) |
| OS thread stack | ~2.5 MB each | shared (4 threads total) |
| OS threads at 10K | 10,000 | 4 (configurable) |
| Total RAM at 10K | ~30 GB | ~3.7 GB (full) / ~540 MB (bare) |

See [`bench/`](https://github.com/elixir-volt/quickbeam/tree/master/bench) for details.

## When to use what

| Use case | Module | Why |
|---|---|---|
| One-off eval, scripting | `QuickBEAM` (Runtime) | Simple, full isolation |
| SSR request pool | `QuickBEAM.Pool` | Checkout/checkin with reset |
| Per-connection state (LiveView) | `QuickBEAM.Context` | Lightweight, thousands concurrent |
| Sandboxed user code | `QuickBEAM` with `apis: false` | Memory limits, timeouts |

## Examples

- [`examples/ssr/`](https://github.com/elixir-volt/quickbeam/tree/master/examples/ssr) — Preact SSR with a pool of runtimes
  and native DOM. Elixir reads the DOM directly — no `renderToString`.
- [`examples/rule_engine/`](https://github.com/elixir-volt/quickbeam/tree/master/examples/rule_engine) — user-defined business
  rules (pricing, validation, transforms) in sandboxed JS runtimes with
  `apis: false`, memory limits, timeouts, and hot reload.
- [`examples/live_dashboard/`](https://github.com/elixir-volt/quickbeam/tree/master/examples/live_dashboard) — Workers (BEAM
  processes) compute metrics in parallel and broadcast results via
  BroadcastChannel (`:pg`). Crash recovery via OTP supervisor.

## License

MIT
