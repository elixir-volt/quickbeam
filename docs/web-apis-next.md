# Web APIs — Next Wave

Design doc for the next batch of Web APIs, all powered by Erlang/OTP.

## Architecture recap

```
JS (QuickJS-NG)              Zig NIF              Elixir/OTP
─────────────────    ─────────────────────    ─────────────────
beam.callSync(…) →   js_to_beam → send →     handle_info(:beam_call)
                     ← wait ← slot.done      handler.(args)
                     beam_to_js ←             resolve_call_term

beam.call(…)     →   Promise + call_id →     handle_info(:beam_call)
                     ← resolve/reject         resolve_call_term
```

TypeScript polyfills in `priv/ts/` → bundled to `priv/js/` → loaded at runtime init.
BEAM handlers registered in `Runtime.@builtin_handlers`.

## 1. `crypto.randomUUID()`

**Effort**: tiny — no new files, pure Elixir one-liner.

**BEAM backend**: `:crypto.strong_rand_bytes(16)` with RFC 4122 v4 bit twiddling.

**Implementation**: Add to `priv/ts/crypto-subtle.ts`:

```ts
crypto.randomUUID = function(): string {
  return beam.callSync("__crypto_random_uuid") as string;
};
```

**Elixir handler**:

```elixir
def random_uuid(_args) do
  <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
  <<a::48, 4::4, b::12, 2::2, c::62>>
  |> Base.encode16(case: :lower)
  |> then(fn hex ->
    <<a::binary-8, ?-, b::binary-4, ?-, c::binary-4, ?-, d::binary-4, ?-, e::binary-12>> = hex
    "#{a}-#{b}-#{c}-#{d}-#{e}"
  end)
end
```

**Alternative**: pure Zig using `std.crypto.random` — avoids the NIF→BEAM round-trip entirely. Probably better since it's a leaf operation with no OTP dependency.

---

## 2. `AbortController` / `AbortSignal`

**Effort**: small — pure TypeScript, no BEAM calls.

These are JS-side coordination primitives. The signal is just an `EventTarget` with
an `aborted` boolean. The controller sets it and dispatches `"abort"`.

**Implementation** (`priv/ts/abort.ts`):

```ts
class AbortSignal extends EventTarget {
  #aborted = false;
  #reason: unknown = undefined;

  get aborted() { return this.#aborted; }
  get reason() { return this.#reason; }

  throwIfAborted() {
    if (this.#aborted) throw this.#reason;
  }

  // internal — called by AbortController
  _abort(reason?: unknown) {
    if (this.#aborted) return;
    this.#aborted = true;
    this.#reason = reason ?? new DOMException("The operation was aborted.", "AbortError");
    this.dispatchEvent(new Event("abort"));
  }

  static timeout(ms: number): AbortSignal {
    const controller = new AbortController();
    setTimeout(() => controller.abort(
      new DOMException("The operation timed out.", "TimeoutError")
    ), ms);
    return controller.signal;
  }

  static abort(reason?: unknown): AbortSignal {
    const signal = new AbortSignal();
    signal._abort(reason);
    return signal;
  }
}

class AbortController {
  #signal = new AbortSignal();
  get signal() { return this.#signal; }
  abort(reason?: unknown) { this.#signal._abort(reason); }
}
```

**Prerequisite**: `EventTarget` and `Event` classes. QuickJS-NG doesn't provide these
(they're DOM, not ECMAScript). We need minimal implementations:

```ts
class Event {
  type: string;
  constructor(type: string) { this.type = type; }
}

class EventTarget {
  #listeners = new Map<string, Set<Function>>();

  addEventListener(type: string, listener: Function) {
    if (!this.#listeners.has(type)) this.#listeners.set(type, new Set());
    this.#listeners.get(type)!.add(listener);
  }

  removeEventListener(type: string, listener: Function) {
    this.#listeners.get(type)?.delete(listener);
  }

  dispatchEvent(event: Event): boolean {
    for (const fn of this.#listeners.get(event.type) ?? []) fn(event);
    return true;
  }
}
```

Also need a minimal `DOMException`:

```ts
class DOMException extends Error {
  code: number;
  constructor(message?: string, name = "Error") {
    super(message);
    this.name = name;
    this.code = 0;
  }
}
```

These three (`Event`, `EventTarget`, `DOMException`) are foundational — they'll be
used by fetch, WebSocket, streams, BroadcastChannel, etc.

---

## 3. `fetch()` / `Request` / `Response` / `Headers`

**Effort**: large — the biggest single API, but highest value.

**BEAM backend**: `:httpc` (zero deps, ships with OTP).

### Headers

Pure TypeScript. A case-insensitive multimap:

```ts
class Headers {
  #map = new Map<string, string[]>();

  append(name: string, value: string) { ... }
  get(name: string): string | null { ... }  // returns joined with ", "
  set(name: string, value: string) { ... }
  delete(name: string) { ... }
  has(name: string): boolean { ... }
  forEach(cb) { ... }
  entries() / keys() / values() / [Symbol.iterator]()
}
```

### Request

Mostly a data-holder. Pure TypeScript:

```ts
class Request {
  readonly url: string;
  readonly method: string;
  readonly headers: Headers;
  readonly body: ... ;
  readonly signal: AbortSignal;
  // redirect, mode, credentials — can stub initially
}
```

### Response

Wraps the BEAM result:

```ts
class Response {
  readonly status: number;
  readonly statusText: string;
  readonly headers: Headers;
  readonly ok: boolean;           // status 200-299
  readonly url: string;

  async text(): Promise<string> { ... }
  async json(): Promise<unknown> { ... }
  async arrayBuffer(): Promise<ArrayBuffer> { ... }
  // blob() — once we have Blob
}
```

### fetch()

The core — delegates to BEAM:

```ts
async function fetch(input: string | Request, init?: RequestInit): Promise<Response> {
  const request = input instanceof Request ? input : new Request(input, init);

  // Check abort before sending
  request.signal.throwIfAborted();

  const result = await beam.call("__fetch", {
    url: request.url,
    method: request.method,
    headers: [...request.headers.entries()],
    body: request.body ? await readBody(request.body) : null,
  });

  return new Response(result.status, result.statusText, result.headers, result.body, request.url);
}
```

### Elixir handler

```elixir
defmodule QuickBEAM.Fetch do
  def fetch([%{"url" => url, "method" => method, "headers" => headers, "body" => body}]) do
    uri = URI.parse(url)
    scheme = String.to_atom(uri.scheme)
    host = ~c"#{uri.host}"
    port = uri.port
    path = "#{uri.path || "/"}#{if uri.query, do: "?#{uri.query}", else: ""}"

    headers = Enum.map(headers, fn [k, v] -> {~c"#{k}", ~c"#{v}"} end)

    http_method = method |> String.downcase() |> String.to_atom()

    request =
      case body do
        nil -> {~c"#{scheme}://#{host}:#{port}#{path}", headers}
        _ -> {~c"#{scheme}://#{host}:#{port}#{path}", headers, ~c"application/octet-stream", body}
      end

    case :httpc.request(http_method, request, [{:ssl, ssl_opts()}], [body_format: :binary]) do
      {:ok, {{_, status, reason}, resp_headers, resp_body}} ->
        %{
          "status" => status,
          "statusText" => List.to_string(reason),
          "headers" => Enum.map(resp_headers, fn {k, v} -> [to_string(k), to_string(v)] end),
          "body" => {:bytes, IO.iodata_to_binary(resp_body)}
        }

      {:error, reason} ->
        raise "fetch failed: #{inspect(reason)}"
    end
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end
end
```

Uses **zero external deps** — `:httpc`, `:ssl`, `:public_key` are all OTP built-ins.
`:public_key.cacerts_get()` (OTP 25+) loads system CA certs automatically.

### Abort support

When `signal` fires `"abort"`, we need to cancel the in-flight `:httpc` request:

```elixir
# Start the request with async option
{:ok, request_id} = :httpc.request(method, request, ssl_opts, [{:sync, false}])

# If abort message received:
:httpc.cancel_request(request_id)
```

This maps to `beam.call` (async) rather than `beam.callSync`. The BEAM handler
spawns a process that owns the HTTP request and listens for cancel messages.

---

## 4. `ReadableStream`

**Effort**: medium — foundational primitive for streaming fetch responses.

### Design

A `ReadableStream` wraps a source that produces chunks. For QuickBEAM, the
interesting case is a BEAM process that sends chunks into the JS runtime.

```
BEAM process               JS ReadableStream
─────────────              ──────────────────
send(chunk) ──────────→    reader.read() resolves
send(:done)  ──────────→   reader.read() → {done: true}
```

### Minimal implementation

For the initial version, we only need:

1. **`ReadableStream` with a pull source** — enough for `Response.body`
2. **`ReadableStream.prototype.getReader()`** — returns a `ReadableStreamDefaultReader`
3. **Reader has `.read()` → `Promise<{value, done}>`** and `.cancel()`

```ts
class ReadableStream {
  #source: UnderlyingSource;
  #controller: ReadableStreamDefaultController;

  constructor(source?: UnderlyingSource) {
    this.#controller = new ReadableStreamDefaultController();
    this.#source = source ?? {};
    this.#source.start?.(this.#controller);
  }

  getReader(): ReadableStreamDefaultReader {
    return new ReadableStreamDefaultReader(this.#controller);
  }

  async *[Symbol.asyncIterator]() {
    const reader = this.getReader();
    try {
      while (true) {
        const { value, done } = await reader.read();
        if (done) break;
        yield value;
      }
    } finally {
      reader.releaseLock();
    }
  }
}
```

For `Response.body`, the stream is backed by the already-received body bytes
(non-streaming initially). Streaming can come later by having the BEAM handler
send chunks via `send_message`.

---

## 5. `Blob`

**Effort**: small-medium — mostly pure TypeScript.

```ts
class Blob {
  #parts: Uint8Array[];
  #type: string;

  constructor(parts?: BlobPart[], options?: BlobPropertyBag) {
    this.#type = options?.type ?? "";
    this.#parts = (parts ?? []).map(normalizePart);
  }

  get size(): number { return this.#parts.reduce((s, p) => s + p.length, 0); }
  get type(): string { return this.#type; }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return concat(this.#parts).buffer;
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(await this.arrayBuffer());
  }

  async bytes(): Promise<Uint8Array> {
    return concat(this.#parts);
  }

  slice(start?: number, end?: number, contentType?: string): Blob {
    const bytes = concat(this.#parts);
    const s = clampIndex(start ?? 0, bytes.length);
    const e = clampIndex(end ?? bytes.length, bytes.length);
    return new Blob([bytes.slice(s, e)], { type: contentType ?? "" });
  }

  stream(): ReadableStream {
    const bytes = concat(this.#parts);
    return new ReadableStream({
      start(controller) {
        controller.enqueue(bytes);
        controller.close();
      }
    });
  }
}
```

No BEAM calls needed — this is pure JS over binary data.

---

## 6. `BroadcastChannel`

**Effort**: small — elegant OTP mapping.

**BEAM backend**: `:pg` (OTP 23+ process groups).

Each `BroadcastChannel` instance registers its runtime's PID in a `:pg` group
named after the channel. `postMessage` broadcasts to all members except self.

### TypeScript

```ts
class BroadcastChannel extends EventTarget {
  #name: string;

  constructor(name: string) {
    super();
    this.#name = name;
    beam.call("__broadcast_join", name);
  }

  get name() { return this.#name; }

  postMessage(message: unknown) {
    beam.call("__broadcast_post", this.#name, message);
  }

  close() {
    beam.call("__broadcast_leave", this.#name);
  }
}
```

Incoming messages arrive via `send_message` → trigger `"message"` event handlers.

### Elixir handler

```elixir
defmodule QuickBEAM.BroadcastChannel do
  def join([name]) do
    :pg.join(__MODULE__, name, self())
    :ok
  end

  def post([name, message]) do
    self_pid = self()
    for pid <- :pg.get_members(__MODULE__, name), pid != self_pid do
      send(pid, {:broadcast_message, name, message})
    end
    :ok
  end

  def leave([name]) do
    :pg.leave(__MODULE__, name, self())
    :ok
  end
end
```

Handle incoming broadcasts in `Runtime.handle_info`:

```elixir
def handle_info({:broadcast_message, name, message}, state) do
  QuickBEAM.Native.send_message(state.resource, %{
    "type" => "broadcast",
    "channel" => name,
    "data" => message
  })
  {:noreply, state}
end
```

**Unique power**: works across BEAM nodes in a cluster via `:pg`'s distributed
membership. A JS runtime on node A can broadcast to a JS runtime on node B.

---

## 7. `WebSocket`

**Effort**: medium — needs a WebSocket client library or raw `:gen_tcp` + framing.

**BEAM backend**: `:gun` or Mint.WebSocket (or raw TCP + frame codec).

### Design

Each `WebSocket` instance maps to a BEAM process that owns the TCP connection:

```
JS: new WebSocket(url)
  → beam.call("__ws_connect", url, protocols)
  → BEAM spawns a process, connects via :gun
  → on open:  send_message({type: "ws_open", id})
  → on msg:   send_message({type: "ws_message", id, data})
  → on close: send_message({type: "ws_close", id, code, reason})
  → on error: send_message({type: "ws_error", id, reason})

JS: ws.send(data)
  → beam.call("__ws_send", id, data)
  → BEAM process sends frame

JS: ws.close(code, reason)
  → beam.call("__ws_close", id, code, reason)
  → BEAM process sends close frame
```

### TypeScript

```ts
class WebSocket extends EventTarget {
  static CONNECTING = 0;
  static OPEN = 1;
  static CLOSING = 2;
  static CLOSED = 3;

  #url: string;
  #readyState = WebSocket.CONNECTING;
  #id: string;

  onopen: ((ev: Event) => void) | null = null;
  onmessage: ((ev: MessageEvent) => void) | null = null;
  onclose: ((ev: CloseEvent) => void) | null = null;
  onerror: ((ev: Event) => void) | null = null;

  constructor(url: string, protocols?: string | string[]) {
    super();
    this.#url = url;
    this.#id = beam.callSync("__ws_connect", url, protocols) as string;
    // BEAM process will send_message events as connection progresses
  }

  get url() { return this.#url; }
  get readyState() { return this.#readyState; }

  send(data: string | ArrayBuffer | Uint8Array) { ... }
  close(code?: number, reason?: string) { ... }
}
```

### Dependency choice

For zero-dep, we could use `:httpc` to do the HTTP upgrade handshake and then
take over the socket with raw `:gen_tcp` / `:ssl` + WebSocket frame codec.
But this is a lot of frame parsing code.

Better: add `:gun` (or `mint_web_socket`) as an **optional** dependency.
The handler module checks if the dep is available at compile time:

```elixir
if Code.ensure_loaded?(:gun) do
  # use :gun
else
  # raise "WebSocket support requires :gun dependency"
end
```

---

## Implementation order

```
1. Event/EventTarget/DOMException  (foundation — pure TS)
2. crypto.randomUUID()             (trivial — Zig or Elixir)
3. AbortController/AbortSignal     (pure TS, needs EventTarget)
4. Blob                            (pure TS)
5. Headers                         (pure TS)
6. ReadableStream (minimal)        (pure TS)
7. Request / Response              (pure TS, uses Headers + Blob)
8. fetch()                         (TS + Elixir :httpc handler)
9. BroadcastChannel                (TS + Elixir :pg handler)
10. WebSocket                      (TS + Elixir :gun handler)
```

Steps 1-7 are pure TypeScript with no new BEAM code — they can be shipped as
one batch. Step 8 (fetch) is the big BEAM integration. Steps 9-10 add OTP
networking superpowers.

## File layout

```
priv/ts/
  quickbeam.d.ts          ← extend with new types
  event-target.ts         ← Event, EventTarget, DOMException (NEW)
  abort.ts                ← AbortController, AbortSignal (NEW)
  blob.ts                 ← Blob (NEW)
  headers.ts              ← Headers (NEW)
  streams.ts              ← ReadableStream (NEW)
  fetch.ts                ← fetch, Request, Response (NEW)
  broadcast-channel.ts    ← BroadcastChannel (NEW)
  websocket.ts            ← WebSocket (NEW)

lib/quickbeam/
  fetch.ex                ← :httpc handler (NEW)
  broadcast_channel.ex    ← :pg handler (NEW)
  websocket.ex            ← :gun handler (NEW)
```
