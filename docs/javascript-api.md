# JavaScript API Reference

Every QuickBEAM runtime provides the globals listed below.
APIs marked with ★ are unique to QuickBEAM — they have no Web or Node.js
equivalent.

## Always available

These are installed on every runtime, even with `apis: false`.

### Beam ★

The bridge between JavaScript and the BEAM.

| API | Description |
|---|---|
| `Beam.call(name, ...args)` | Call a named Elixir handler. Returns a Promise. |
| `Beam.callSync(name, ...args)` | Call a named Elixir handler, blocking the JS thread until it returns. |
| `Beam.send(pid, message)` | Send a message to a BEAM process. Fire-and-forget. |
| `Beam.self()` | Get the PID of the owning GenServer. |
| `Beam.onMessage(callback)` | Register a callback for incoming BEAM messages. |
| `Beam.monitor(pid, callback)` | Monitor a process. Callback fires with exit reason. |
| `Beam.demonitor(ref)` | Cancel a monitor. |
| `Beam.peek(promise)` | Read a promise's value synchronously. Returns the promise itself if pending. Native implementation via QuickJS `JS_PromiseState`. |
| `Beam.peek.status(promise)` | Returns `'fulfilled'`, `'rejected'`, or `'pending'`. |
| `Beam.version` | QuickBEAM version string (lazy getter). |
| `Beam.sleep(ms)` | Async sleep. Returns a Promise. |
| `Beam.sleepSync(ms)` | Blocks the JS thread for the given milliseconds. |
| `Beam.hash(data, range?)` | Fast non-cryptographic hash via `:erlang.phash2`. |
| `Beam.escapeHTML(str)` | Escape `& < > " '` for safe HTML insertion. |
| `Beam.which(bin)` | Find an executable on PATH. Returns absolute path or `null`. |
| `Beam.randomUUIDv7()` | Monotonic, sortable UUID v7. |
| `Beam.deepEquals(a, b)` | Deep structural equality check. |
| `Beam.semver.satisfies(version, range)` | Check version against a requirement (Elixir `Version` syntax). |
| `Beam.semver.order(a, b)` | Compare two semver strings. Returns `-1`, `0`, `1`, or `null`. |
| `Beam.nodes()` | List connected BEAM nodes (including self). |
| `Beam.rpc(node, runtime, fn, ...args)` | Call a function on a named runtime on a remote BEAM node. |
| `Beam.spawn(script)` | Spawn a new JS runtime process evaluating the given script. Returns PID. |
| `Beam.register(name)` | Register this runtime under a name for discovery. |
| `Beam.whereis(name)` | Look up a registered runtime by name. Returns PID or `null`. |
| `Beam.link(pid)` | Create a bidirectional link with another BEAM process. |
| `Beam.unlink(pid)` | Remove a bidirectional link. |
| `Beam.systemInfo()` | BEAM VM introspection: schedulers, memory, process count, OTP release. |
| `Beam.processInfo()` | Info about the owning GenServer: memory, reductions, message queue, status. |
| `Beam.password.hash(pw, opts?)` | Hash a password with PBKDF2-SHA256. Returns PHC-format string. Default 600k iterations. |
| `Beam.password.verify(pw, hash)` | Verify a password against a hash. Constant-time comparison. |

### Timers

| API | Description |
|---|---|
| `setTimeout(fn, ms, ...args)` | Schedule a callback. |
| `setInterval(fn, ms, ...args)` | Schedule a repeating callback. |
| `clearTimeout(id)` | Cancel a timeout. |
| `clearInterval(id)` | Cancel an interval. |

### Console

| API | Description |
|---|---|
| `console.log(...args)` | Log to the BEAM (sends `{:console, "log", message}` to the owner). |
| `console.info(...args)` | Alias for `console.log`. |
| `console.warn(...args)` | Log with `"warn"` level. |
| `console.error(...args)` | Log with `"error"` level. |
| `console.debug(...args)` | Alias for `console.log`. |
| `console.trace(...args)` | Log with stack trace. |
| `console.assert(cond, ...args)` | Log error if condition is falsy. |
| `console.time(label?)` | Start a named timer. |
| `console.timeLog(label?, ...args)` | Log elapsed time. |
| `console.timeEnd(label?)` | Log elapsed time and remove timer. |
| `console.count(label?)` | Log invocation count. |
| `console.countReset(label?)` | Reset a counter. |
| `console.dir(obj)` | Log a JSON representation. |
| `console.group(...args)` | Increase indent. |
| `console.groupEnd()` | Decrease indent. |

### Encoding

| API | Description |
|---|---|
| `TextEncoder` | Encode strings to UTF-8. Native Zig implementation. |
| `TextDecoder` | Decode UTF-8 (and label aliases). Supports `fatal` and `ignoreBOM` options. Native Zig. |
| `atob(data)` | Decode a base64 string. Native Zig. |
| `btoa(data)` | Encode a string to base64. Native Zig. |

### Other core globals

| API | Description |
|---|---|
| `crypto.getRandomValues(typedArray)` | Fill a typed array with cryptographically random values. Native Zig. |
| `performance.now()` | High-resolution monotonic timestamp in milliseconds. Native Zig. |
| `queueMicrotask(fn)` | Schedule a microtask. |
| `structuredClone(value)` | Deep clone via QuickJS serialization. |

---

## Browser APIs (`apis: :browser`)

Loaded by default. These are Web platform APIs backed by OTP.

### Fetch

| API | Backed by |
|---|---|
| `fetch(url, init?)` | Req (Finch HTTP client) |
| `Request` | — |
| `Response` | — |
| `Headers` | — |

### URL

| API | Backed by |
|---|---|
| `URL` | Elixir `:uri_string` |
| `URLSearchParams` | — |

### Streams

| API | Description |
|---|---|
| `ReadableStream` | — |
| `ReadableStreamDefaultReader` | — |
| `WritableStream` | — |
| `WritableStreamDefaultWriter` | — |
| `TransformStream` | — |
| `TextEncoderStream` | — |
| `TextDecoderStream` | — |

### Blob / File

| API | Description |
|---|---|
| `Blob` | Pure TS. Supports all typed array variants, `slice()`, `text()`, `arrayBuffer()`, `bytes()`, `stream()`. |
| `File` | Extends Blob with `name` and `lastModified`. |

### Events

| API | Description |
|---|---|
| `Event` | — |
| `MessageEvent` | — |
| `CloseEvent` | — |
| `ErrorEvent` | — |
| `CustomEvent` | — |
| `EventTarget` | — |

### Abort

| API | Description |
|---|---|
| `AbortController` | — |
| `AbortSignal` | Supports `timeout()` and `any()` static methods. |

### Crypto

| API | Backed by |
|---|---|
| `crypto.subtle.digest(algo, data)` | `:crypto.hash` |
| `crypto.subtle.generateKey(algo, ...)` | `:crypto.generate_key` |
| `crypto.subtle.sign(algo, key, data)` | `:crypto.sign` |
| `crypto.subtle.verify(algo, key, sig, data)` | `:crypto.verify` |
| `crypto.subtle.encrypt(algo, key, data)` | `:crypto.crypto_one_time_aead` |
| `crypto.subtle.decrypt(algo, key, data)` | `:crypto.crypto_one_time_aead` |
| `crypto.subtle.deriveBits(algo, key, len)` | `:crypto` |
| `crypto.subtle.deriveKey(algo, key, ...)` | — |
| `crypto.subtle.importKey(fmt, data, algo, ...)` | — |
| `crypto.subtle.exportKey(fmt, key)` | — |
| `crypto.randomUUID()` | — |

### Communication

| API | Backed by |
|---|---|
| `BroadcastChannel` | `:pg` (distributed process groups) |
| `MessageChannel` / `MessagePort` | — |
| `WebSocket` | `:gun` |
| `EventSource` | `:httpc` streaming |
| `Worker` | Spawns a separate BEAM GenServer with its own JS runtime |

### Storage

| API | Backed by |
|---|---|
| `localStorage.getItem/setItem/removeItem/clear/key/length` | ETS (per-runtime namespace) |

### Locks

| API | Backed by |
|---|---|
| `navigator.locks.request(name, cb)` | GenServer with monitors |
| `navigator.locks.request(name, opts, cb)` | Supports `mode`, `ifAvailable`, `signal` |
| `navigator.locks.query()` | — |

### Compression ★

| API | Backed by |
|---|---|
| `compression.compress(format, data)` | `:zlib` |
| `compression.decompress(format, data)` | `:zlib` |
| `CompressionStream` | — |
| `DecompressionStream` | — |

Formats: `gzip`, `deflate`, `deflate-raw`.

### Performance (extended)

| API | Description |
|---|---|
| `performance.now()` | Native Zig (see core globals). |
| `performance.timeOrigin` | — |
| `performance.mark(name, opts?)` | — |
| `performance.measure(name, start?, end?)` | — |
| `performance.getEntries()` | — |
| `performance.getEntriesByType(type)` | — |
| `performance.getEntriesByName(name, type?)` | — |
| `performance.clearMarks(name?)` | — |
| `performance.clearMeasures(name?)` | — |
| `performance.toJSON()` | — |

### Other

| API | Description |
|---|---|
| `FormData` | — |
| `DOMException` | — |
| `Buffer` | Node-compatible Buffer (available in browser mode too). |

---

## Node.js APIs (`apis: :node`)

Enable with `apis: :node` or `apis: [:browser, :node]`.

### process

| API | Description |
|---|---|
| `process.env` | Live `Proxy` over `System.get_env/put_env`. Supports get, set, delete, `in`, `Object.keys`. |
| `process.argv` | `['beam', 'quickbeam']` |
| `process.platform` | Via `Beam.callSync` → `:os.type()` |
| `process.arch` | Via `Beam.callSync` → `:erlang.system_info(:system_architecture)` |
| `process.pid` | Via `Beam.callSync` → `:os.getpid()` |
| `process.cwd()` | Via `Beam.callSync` → `File.cwd!()` |
| `process.exit(code?)` | — |
| `process.nextTick(fn, ...args)` | Alias for `queueMicrotask`. |
| `process.hrtime(prev?)` | High-resolution time. |
| `process.hrtime.bigint()` | Nanosecond precision. |
| `process.stdout.write(str)` | Via `console.log`. |
| `process.stderr.write(str)` | Via `console.error`. |
| `process.version` | `'v22.0.0'` |

### path

| API | Description |
|---|---|
| `path.join(...parts)` | — |
| `path.resolve(...parts)` | — |
| `path.dirname(p)` | — |
| `path.basename(p, ext?)` | — |
| `path.extname(p)` | — |
| `path.isAbsolute(p)` | — |
| `path.normalize(p)` | — |
| `path.relative(from, to)` | — |
| `path.parse(p)` | — |
| `path.format(obj)` | — |
| `path.sep` | `'/'` |
| `path.delimiter` | `':'` |

### fs

| API | Backed by |
|---|---|
| `fs.readFileSync(path, opts?)` | `Beam.callSync` → `File.read!` |
| `fs.writeFileSync(path, data, opts?)` | `Beam.callSync` → `File.write!` |
| `fs.appendFileSync(path, data, opts?)` | — |
| `fs.existsSync(path)` | — |
| `fs.mkdirSync(path, opts?)` | — |
| `fs.readdirSync(path)` | — |
| `fs.statSync(path)` | — |
| `fs.lstatSync(path)` | — |
| `fs.unlinkSync(path)` | — |
| `fs.renameSync(old, new)` | — |
| `fs.rmSync(path, opts?)` | — |
| `fs.copyFileSync(src, dest)` | — |
| `fs.realpathSync(path)` | — |
| `fs.readFile(path, opts?, cb)` | Async callback style. |
| `fs.writeFile(path, data, opts?, cb)` | Async callback style. |

### os

| API | Description |
|---|---|
| `os.platform()` | — |
| `os.arch()` | — |
| `os.type()` | — |
| `os.release()` | — |
| `os.hostname()` | — |
| `os.homedir()` | — |
| `os.tmpdir()` | — |
| `os.cpus()` | — |
| `os.totalmem()` | — |
| `os.freemem()` | — |
| `os.uptime()` | — |
| `os.networkInterfaces()` | — |
| `os.endianness()` | — |
| `os.EOL` | `'\n'` |

### child_process

| API | Backed by |
|---|---|
| `child_process.execSync(cmd, opts?)` | `Beam.callSync` → `System.cmd` |
| `child_process.exec(cmd, opts?, cb)` | `Beam.call` → `System.cmd` |

---

## DOM

Every runtime has a live DOM tree backed by lexbor (C library).
Elixir can read the same tree through `QuickBEAM.dom_*` functions
without JS execution.

### document

| API | Description |
|---|---|
| `document.createElement(tag)` | — |
| `document.createElementNS(ns, tag)` | — |
| `document.createTextNode(text)` | — |
| `document.createDocumentFragment()` | — |
| `document.createComment(text)` | — |
| `document.getElementById(id)` | — |
| `document.getElementsByClassName(name)` | — |
| `document.getElementsByTagName(tag)` | — |
| `document.querySelector(selector)` | CSS selector matching via lexbor. |
| `document.querySelectorAll(selector)` | — |
| `document.addEventListener/removeEventListener/dispatchEvent` | — |
| `document.body` | Getter. |
| `document.head` | Getter. |
| `document.documentElement` | Getter. |
| `document.nodeType` | Returns `9` (DOCUMENT_NODE). |
| `document.nodeName` | Returns `"#document"`. |

### Element

**Properties** (getters/setters):

`id`, `className`, `classList` (DOMTokenList), `style` (CSSStyleDeclaration),
`tagName`, `nodeName`, `nodeType`, `nodeValue`, `innerHTML`, `outerHTML`,
`textContent`, `parentNode`, `parentElement`, `children`, `childNodes`,
`firstChild`, `lastChild`, `nextSibling`, `previousSibling`

**Methods**:

`querySelector`, `querySelectorAll`, `getElementsByClassName`,
`getElementsByTagName`, `matches`, `closest`, `getAttribute`,
`setAttribute`, `removeAttribute`, `hasAttribute`, `appendChild`,
`removeChild`, `insertBefore`, `replaceChild`, `cloneNode`, `contains`,
`remove`, `before`, `after`, `prepend`, `append`, `replaceWith`,
`addEventListener`, `removeEventListener`, `dispatchEvent`

### CSSStyleDeclaration

`getPropertyValue(prop)`, `setProperty(prop, value, priority?)`,
`removeProperty(prop)`, `getPropertyPriority(prop)`, `cssText` (getter),
plus direct property access (`el.style.color = 'red'`).

### DOMTokenList (classList)

`add(token)`, `remove(token)`, `toggle(token)`, `contains(token)`,
`replace(old, new)`, `item(index)`, `length`, `value`,
`forEach(callback)`, `entries()`, `keys()`, `values()`.

### MutationObserver

No-op stub for SSR compatibility. `observe()`, `disconnect()`, and
`takeRecords()` are defined but do nothing.

### Prototype chain and instanceof

DOM nodes have a spec-compliant prototype hierarchy. Constructor
globals (`Node`, `Element`, `HTMLElement`, `SVGElement`,
`MathMLElement`, `Document`, `DocumentFragment`, `Text`, `Comment`)
are on `globalThis`:

```js
document.createElement('div') instanceof HTMLElement  // true
document.createElement('div') instanceof Element      // true
document.createElement('div') instanceof Node         // true
document.createElementNS('http://www.w3.org/2000/svg', 'svg') instanceof SVGElement  // true
```

`Object.prototype.toString.call(el)` returns type-specific tags like
`[object HTMLDivElement]`, `[object HTMLAnchorElement]`, etc.

### Node identity

The same DOM node always returns the same JS wrapper, so `===` works:

```js
document.body === document.body       // true
child.parentNode === parent           // true
el.firstChild === el.firstChild       // true
```

### getComputedStyle(el)

Returns the element's `CSSStyleDeclaration`.

---

## QuickJS built-ins

These come from QuickJS-NG itself (not QuickBEAM polyfills):

- Full ES2023: `Promise`, `Map`, `Set`, `WeakMap`, `WeakSet`, `Proxy`,
  `Symbol`, `BigInt`, generators, async/await, optional chaining,
  nullish coalescing, etc.
- `ArrayBuffer`, `SharedArrayBuffer`, all typed arrays
- `JSON`, `Math`, `Date`, `RegExp`, `Intl` (partial)
- `eval`, `globalThis`
