(() => {
  // priv/ts/event-target.ts
  var SYM_STOP_IMMEDIATE = Symbol("stopImmediate");

  class QBEvent {
    type;
    timeStamp;
    cancelBubble = false;
    #stopImmediatePropagationFlag = false;
    #defaultPrevented = false;
    constructor(type) {
      this.type = type;
      this.timeStamp = performance.now();
    }
    get defaultPrevented() {
      return this.#defaultPrevented;
    }
    preventDefault() {
      this.#defaultPrevented = true;
    }
    stopPropagation() {
      this.cancelBubble = true;
    }
    stopImmediatePropagation() {
      this.#stopImmediatePropagationFlag = true;
      this.cancelBubble = true;
    }
    get [SYM_STOP_IMMEDIATE]() {
      return this.#stopImmediatePropagationFlag;
    }
  }

  class QBMessageEvent extends QBEvent {
    data;
    origin;
    lastEventId;
    constructor(type, init) {
      super(type);
      this.data = init?.data;
      this.origin = init?.origin ?? "";
      this.lastEventId = init?.lastEventId ?? "";
    }
  }

  class QBCloseEvent extends QBEvent {
    code;
    reason;
    wasClean;
    constructor(type, init) {
      super(type);
      this.code = init?.code ?? 0;
      this.reason = init?.reason ?? "";
      this.wasClean = init?.wasClean ?? false;
    }
  }

  class QBErrorEvent extends QBEvent {
    message;
    error;
    constructor(type, init) {
      super(type);
      this.message = init?.message ?? "";
      this.error = init?.error;
    }
  }

  class QBEventTarget {
    #listeners = new Map;
    addEventListener(type, callback, options) {
      if (callback === null)
        return;
      const once = typeof options === "object" ? options.once ?? false : false;
      const signal = typeof options === "object" ? options.signal : undefined;
      const list = this.#listeners.get(type);
      if (list) {
        for (const entry2 of list) {
          if (entry2.callback === callback)
            return;
        }
      }
      const entry = { callback, once, signal };
      if (signal?.aborted)
        return;
      signal?.addEventListener("abort", () => {
        this.removeEventListener(type, callback);
      });
      if (list) {
        list.push(entry);
      } else {
        this.#listeners.set(type, [entry]);
      }
    }
    removeEventListener(type, callback) {
      if (callback === null)
        return;
      const list = this.#listeners.get(type);
      if (!list)
        return;
      for (let i = 0;i < list.length; i++) {
        if (list[i].callback === callback) {
          list[i]._removed = true;
          list.splice(i, 1);
          break;
        }
      }
      if (list.length === 0)
        this.#listeners.delete(type);
    }
    dispatchEvent(event) {
      const list = this.#listeners.get(event.type);
      if (!list)
        return !event.defaultPrevented;
      const snapshot = list.slice();
      for (const entry of snapshot) {
        if (entry._removed)
          continue;
        if (event[SYM_STOP_IMMEDIATE])
          break;
        if (typeof entry.callback === "function") {
          entry.callback(event);
        } else {
          entry.callback.handleEvent(event);
        }
        if (entry.once) {
          this.removeEventListener(event.type, entry.callback);
        }
      }
      return !event.defaultPrevented;
    }
  }

  class QBDOMException extends Error {
    code;
    constructor(message = "", name = "Error") {
      super(message);
      this.name = name;
      this.code = 0;
    }
  }
  globalThis.Event = QBEvent;
  globalThis.MessageEvent = QBMessageEvent;
  globalThis.CloseEvent = QBCloseEvent;
  globalThis.ErrorEvent = QBErrorEvent;
  globalThis.EventTarget = QBEventTarget;
  globalThis.DOMException = QBDOMException;

  // priv/ts/abort.ts
  var SYM_ABORT = Symbol("abort");

  class QBAbortSignal extends QBEventTarget {
    #aborted = false;
    #reason = undefined;
    onabort = null;
    get aborted() {
      return this.#aborted;
    }
    get reason() {
      return this.#reason;
    }
    throwIfAborted() {
      if (this.#aborted)
        throw this.#reason;
    }
    [SYM_ABORT](reason) {
      if (this.#aborted)
        return;
      this.#aborted = true;
      this.#reason = reason ?? new QBDOMException("The operation was aborted.", "AbortError");
      const event = new QBEvent("abort");
      this.onabort?.(event);
      this.dispatchEvent(event);
    }
    static timeout(ms) {
      const controller = new QBAbortController;
      setTimeout(() => controller.abort(new QBDOMException("The operation timed out.", "TimeoutError")), ms);
      return controller.signal;
    }
    static abort(reason) {
      const s = new QBAbortSignal;
      s[SYM_ABORT](reason);
      return s;
    }
    static any(signals) {
      const controller = new QBAbortController;
      for (const s of signals) {
        if (s.aborted) {
          controller.abort(s.reason);
          return controller.signal;
        }
        s.addEventListener("abort", () => controller.abort(s.reason), { once: true });
      }
      return controller.signal;
    }
  }

  class QBAbortController {
    #signal = new QBAbortSignal;
    get signal() {
      return this.#signal;
    }
    abort(reason) {
      this.#signal[SYM_ABORT](reason);
    }
  }
  globalThis.AbortSignal = QBAbortSignal;
  globalThis.AbortController = QBAbortController;

  // priv/ts/streams.ts
  var SYM_READ = Symbol("read");
  var SYM_RELEASE = Symbol("releaseLock");
  var SYM_CANCEL = Symbol("cancel");

  class QBReadableStream {
    #queue = [];
    #state = "readable";
    #storedError = undefined;
    #source;
    #controller;
    #pulling = false;
    #waitingReaders = [];
    #locked = false;
    constructor(source) {
      this.#source = source;
      const controller = {
        desiredSize: 1,
        enqueue: (chunk) => {
          if (this.#state !== "readable")
            return;
          if (this.#waitingReaders.length > 0) {
            const reader = this.#waitingReaders.shift();
            if (reader)
              reader.resolve({ value: chunk, done: false });
            return;
          }
          this.#queue.push(chunk);
        },
        close: () => {
          if (this.#state !== "readable")
            return;
          this.#state = "closed";
          for (const reader of this.#waitingReaders) {
            reader.resolve({ value: undefined, done: true });
          }
          this.#waitingReaders = [];
        },
        error: (e) => {
          if (this.#state !== "readable")
            return;
          this.#state = "errored";
          this.#storedError = e;
          for (const reader of this.#waitingReaders) {
            reader.reject(e);
          }
          this.#waitingReaders = [];
          this.#queue = [];
        }
      };
      this.#controller = controller;
      try {
        const result = source?.start?.(controller);
        if (result instanceof Promise) {
          result.catch((e) => controller.error(e));
        }
      } catch (e) {
        controller.error(e);
      }
    }
    get locked() {
      return this.#locked;
    }
    getReader() {
      if (this.#locked)
        throw new TypeError("ReadableStream is already locked");
      this.#locked = true;
      return new QBReadableStreamDefaultReader(this);
    }
    async cancel(reason) {
      if (this.#locked)
        throw new TypeError("Cannot cancel a locked stream");
      await this.#source?.cancel?.(reason);
      this.#state = "closed";
      this.#queue = [];
    }
    [SYM_READ]() {
      if (this.#state === "errored") {
        return Promise.reject(this.#storedError);
      }
      if (this.#queue.length > 0) {
        const value = this.#queue.shift();
        this.#callPull();
        return Promise.resolve({ value, done: false });
      }
      if (this.#state === "closed") {
        return Promise.resolve({ value: undefined, done: true });
      }
      this.#callPull();
      return new Promise((resolve, reject) => {
        this.#waitingReaders.push({ resolve, reject });
      });
    }
    [SYM_RELEASE]() {
      this.#locked = false;
    }
    [SYM_CANCEL](reason) {
      const result = this.#source?.cancel?.(reason);
      return result instanceof Promise ? result : Promise.resolve();
    }
    #callPull() {
      if (this.#pulling || this.#state !== "readable" || !this.#source?.pull)
        return;
      this.#pulling = true;
      try {
        const result = this.#source.pull(this.#controller);
        if (result instanceof Promise) {
          result.then(() => {
            this.#pulling = false;
          }).catch((e) => {
            this.#pulling = false;
            this.#controller.error(e);
          });
        } else {
          this.#pulling = false;
        }
      } catch (e) {
        this.#pulling = false;
        this.#controller.error(e);
      }
    }
    async* [Symbol.asyncIterator]() {
      const reader = this.getReader();
      try {
        for (;; ) {
          const { value, done } = await reader.read();
          if (done)
            break;
          yield value;
        }
      } finally {
        reader.releaseLock();
      }
    }
    tee() {
      const reader = this.getReader();
      let cancelled1 = false;
      let cancelled2 = false;
      let ctrl2;
      const stream1 = new QBReadableStream({
        pull(controller) {
          return reader.read().then(({ value, done }) => {
            if (done) {
              if (!cancelled1)
                controller.close();
              if (!cancelled2)
                ctrl2.close();
              return;
            }
            if (!cancelled1)
              controller.enqueue(value);
            if (!cancelled2)
              ctrl2.enqueue(value);
          });
        },
        cancel() {
          cancelled1 = true;
        }
      });
      const stream2 = new QBReadableStream({
        start(controller) {
          ctrl2 = controller;
        },
        cancel() {
          cancelled2 = true;
        }
      });
      return [stream1, stream2];
    }
    static from(iterable) {
      return new QBReadableStream({
        async start(controller) {
          for await (const chunk of iterable) {
            controller.enqueue(chunk);
          }
          controller.close();
        }
      });
    }
  }

  class QBReadableStreamDefaultReader {
    #stream;
    #closed;
    #closedResolve;
    constructor(stream) {
      this.#stream = stream;
      this.#closed = new Promise((resolve) => {
        this.#closedResolve = resolve;
      });
    }
    get closed() {
      return this.#closed;
    }
    read() {
      return this.#stream[SYM_READ]();
    }
    releaseLock() {
      this.#stream[SYM_RELEASE]();
      this.#closedResolve();
    }
    async cancel(reason) {
      await this.#stream[SYM_CANCEL](reason);
      this.releaseLock();
    }
  }
  globalThis.ReadableStream = QBReadableStream;
  globalThis.ReadableStreamDefaultReader = QBReadableStreamDefaultReader;

  // priv/ts/blob.ts
  var SYM_BYTES = Symbol("bytes");
  function normalizeQBBlobPart(part) {
    if (part instanceof Uint8Array)
      return part;
    if (part instanceof ArrayBuffer)
      return new Uint8Array(part);
    if (part instanceof DataView)
      return new Uint8Array(part.buffer, part.byteOffset, part.byteLength);
    if (part instanceof QBBlob)
      return part[SYM_BYTES]();
    if (typeof part === "string")
      return new TextEncoder().encode(part);
    return new Uint8Array(0);
  }
  function concatBytes(parts) {
    if (parts.length === 0)
      return new Uint8Array(0);
    if (parts.length === 1)
      return parts[0];
    let total = 0;
    for (const p of parts)
      total += p.length;
    const result = new Uint8Array(total);
    let offset = 0;
    for (const p of parts) {
      result.set(p, offset);
      offset += p.length;
    }
    return result;
  }
  function clampIndex(idx, size) {
    if (idx < 0)
      return Math.max(size + idx, 0);
    return Math.min(idx, size);
  }

  class QBBlob {
    #parts;
    #type;
    constructor(parts, options) {
      this.#type = (options?.type ?? "").toLowerCase();
      this.#parts = (parts ?? []).map(normalizeQBBlobPart);
    }
    get size() {
      let total = 0;
      for (const p of this.#parts)
        total += p.length;
      return total;
    }
    get type() {
      return this.#type;
    }
    async arrayBuffer() {
      return this[SYM_BYTES]().buffer;
    }
    async text() {
      return new TextDecoder().decode(this[SYM_BYTES]());
    }
    async bytes() {
      return this[SYM_BYTES]();
    }
    slice(start, end, contentType) {
      const bytes = this[SYM_BYTES]();
      const s = clampIndex(start ?? 0, bytes.length);
      const e = clampIndex(end ?? bytes.length, bytes.length);
      return new QBBlob([bytes.slice(s, Math.max(s, e))], {
        type: contentType ?? ""
      });
    }
    stream() {
      const bytes = this[SYM_BYTES]();
      return new QBReadableStream({
        start(controller) {
          if (bytes.length > 0)
            controller.enqueue(bytes);
          controller.close();
        }
      });
    }
    [SYM_BYTES]() {
      return concatBytes(this.#parts);
    }
  }

  class QBFile extends QBBlob {
    name;
    lastModified;
    constructor(parts, name, options) {
      super(parts, options);
      this.name = name;
      this.lastModified = options?.lastModified ?? Date.now();
    }
  }
  globalThis.Blob = QBBlob;
  globalThis.File = QBFile;

  // priv/ts/headers.ts
  class QBHeaders {
    #map = new Map;
    constructor(init) {
      if (init instanceof QBHeaders) {
        for (const [name, value] of init)
          this.append(name, value);
      } else if (Array.isArray(init)) {
        for (const pair of init)
          this.append(pair[0], pair[1]);
      } else if (init) {
        for (const key of Object.keys(init))
          this.append(key, init[key]);
      }
    }
    append(name, value) {
      const key = name.toLowerCase();
      const existing = this.#map.get(key);
      if (existing) {
        existing.push(value);
      } else {
        this.#map.set(key, [value]);
      }
    }
    get(name) {
      const values = this.#map.get(name.toLowerCase());
      return values ? values.join(", ") : null;
    }
    getSetCookie() {
      return this.#map.get("set-cookie")?.slice() ?? [];
    }
    set(name, value) {
      this.#map.set(name.toLowerCase(), [value]);
    }
    delete(name) {
      this.#map.delete(name.toLowerCase());
    }
    has(name) {
      return this.#map.has(name.toLowerCase());
    }
    forEach(callback, thisArg) {
      for (const [name, value] of this) {
        callback.call(thisArg, value, name, this);
      }
    }
    *entries() {
      const keys = [...this.#map.keys()].sort();
      for (const key of keys) {
        yield [key, this.#map.get(key)?.join(", ") ?? ""];
      }
    }
    *keys() {
      const keys = [...this.#map.keys()].sort();
      for (const key of keys)
        yield key;
    }
    *values() {
      const keys = [...this.#map.keys()].sort();
      for (const key of keys)
        yield this.#map.get(key)?.join(", ") ?? "";
    }
    [Symbol.iterator]() {
      return this.entries();
    }
  }
  globalThis.Headers = QBHeaders;

  // priv/ts/fetch.ts
  async function bodyToBytes(body) {
    if (typeof body === "string") {
      return { bytes: new TextEncoder().encode(body), contentType: "text/plain;charset=UTF-8" };
    }
    if (body instanceof Uint8Array) {
      return { bytes: body, contentType: null };
    }
    if (body instanceof ArrayBuffer) {
      return { bytes: new Uint8Array(body), contentType: null };
    }
    if (body instanceof QBBlob) {
      return { bytes: body[SYM_BYTES](), contentType: body.type || null };
    }
    if (body instanceof URLSearchParams) {
      return {
        bytes: new TextEncoder().encode(body.toString()),
        contentType: "application/x-www-form-urlencoded;charset=UTF-8"
      };
    }
    if (body instanceof QBReadableStream) {
      const reader = body.getReader();
      const chunks = [];
      for (;; ) {
        const { value, done } = await reader.read();
        if (done)
          break;
        chunks.push(value instanceof Uint8Array ? value : new Uint8Array(value));
      }
      let total = 0;
      for (const c of chunks)
        total += c.length;
      const result = new Uint8Array(total);
      let offset = 0;
      for (const c of chunks) {
        result.set(c, offset);
        offset += c.length;
      }
      return { bytes: result, contentType: null };
    }
    return { bytes: null, contentType: null };
  }
  function buildRequestFromExisting(input, init) {
    return {
      url: input.url,
      method: (init?.method ?? input.method).toUpperCase(),
      headers: new QBHeaders(init?.headers ?? input.headers),
      body: init?.body !== undefined ? init.body : input.body,
      signal: init?.signal ?? input.signal,
      redirect: init?.redirect ?? input.redirect
    };
  }
  function buildRequestFromURL(url, init) {
    return {
      url,
      method: (init?.method ?? "GET").toUpperCase(),
      headers: new QBHeaders(init?.headers),
      body: init?.body ?? null,
      signal: init?.signal ?? new QBAbortSignal,
      redirect: init?.redirect ?? "follow"
    };
  }

  class QBRequest {
    url;
    method;
    headers;
    body;
    signal;
    redirect;
    constructor(input, init) {
      const props = input instanceof QBRequest ? buildRequestFromExisting(input, init) : buildRequestFromURL(input, init);
      this.url = props.url;
      this.method = props.method;
      this.headers = props.headers;
      this.body = props.body ?? null;
      this.signal = props.signal;
      this.redirect = props.redirect;
    }
    clone() {
      return new QBRequest(this);
    }
  }

  class QBResponse {
    status;
    statusText;
    headers;
    url;
    redirected;
    type = "basic";
    #body;
    #bodyUsed = false;
    constructor(body, init) {
      this.#body = body;
      this.status = init.status;
      this.statusText = init.statusText;
      this.headers = init.headers;
      this.url = init.url;
      this.redirected = init.redirected ?? false;
    }
    get ok() {
      return this.status >= 200 && this.status < 300;
    }
    get bodyUsed() {
      return this.#bodyUsed;
    }
    get body() {
      if (this.#body === null)
        return null;
      const bytes = this.#body;
      return new QBReadableStream({
        start(controller) {
          if (bytes.length > 0)
            controller.enqueue(bytes);
          controller.close();
        }
      });
    }
    #consumeBody() {
      if (this.#bodyUsed)
        throw new TypeError("Body already consumed");
      this.#bodyUsed = true;
      return this.#body ?? new Uint8Array(0);
    }
    async arrayBuffer() {
      return this.#consumeBody().buffer;
    }
    async bytes() {
      return this.#consumeBody();
    }
    async text() {
      return new TextDecoder().decode(this.#consumeBody());
    }
    async json() {
      return JSON.parse(await this.text());
    }
    async blob() {
      const bytes = this.#consumeBody();
      return new QBBlob([bytes], {
        type: this.headers.get("content-type") ?? ""
      });
    }
    clone() {
      if (this.#bodyUsed)
        throw new TypeError("Cannot clone a used response");
      return new QBResponse(this.#body ? this.#body.slice() : null, {
        status: this.status,
        statusText: this.statusText,
        headers: new QBHeaders(this.headers),
        url: this.url,
        redirected: this.redirected
      });
    }
    static error() {
      return new QBResponse(null, {
        status: 0,
        statusText: "",
        headers: new QBHeaders,
        url: ""
      });
    }
    static redirect(url, status = 302) {
      const headers = new QBHeaders([["location", url]]);
      return new QBResponse(null, { status, statusText: "", headers, url: "" });
    }
    static json(data, init) {
      const body = new TextEncoder().encode(JSON.stringify(data));
      const headers = new QBHeaders(init?.headers);
      if (!headers.has("content-type")) {
        headers.set("content-type", "application/json");
      }
      return new QBResponse(body, {
        status: init?.status ?? 200,
        statusText: "",
        headers,
        url: ""
      });
    }
  }
  async function qbFetch(input, init) {
    const request = input instanceof QBRequest ? input : new QBRequest(input, init);
    request.signal.throwIfAborted();
    let resolvedBody = null;
    let bodyContentType = null;
    if (request.body !== null) {
      const { bytes, contentType } = await bodyToBytes(request.body);
      resolvedBody = bytes;
      bodyContentType = contentType;
    }
    if (bodyContentType && !request.headers.has("content-type")) {
      request.headers.set("content-type", bodyContentType);
    }
    const headerEntries = [...request.headers.entries()];
    const payload = {
      url: request.url,
      method: request.method,
      headers: headerEntries,
      body: resolvedBody,
      redirect: request.redirect
    };
    const resultPromise = beam.call("__fetch", payload);
    const abortPromise = new Promise((_, reject) => {
      if (request.signal.aborted) {
        reject(request.signal.reason);
        return;
      }
      request.signal.addEventListener("abort", () => reject(request.signal.reason), { once: true });
    });
    const result = await Promise.race([resultPromise, abortPromise]);
    const responseHeaders = new QBHeaders(result.headers);
    const responseBody = result.body instanceof Uint8Array ? result.body : null;
    return new QBResponse(responseBody, {
      status: result.status,
      statusText: result.statusText,
      headers: responseHeaders,
      url: result.url || request.url,
      redirected: result.redirected
    });
  }
  globalThis.Request = QBRequest;
  globalThis.Response = QBResponse;
  globalThis.fetch = qbFetch;

  // priv/ts/broadcast-channel.ts
  var SYM_RECEIVE = Symbol("receive");
  var channelRegistry = new Map;
  function registerChannel(ch) {
    let set = channelRegistry.get(ch.name);
    if (!set) {
      set = new Set;
      channelRegistry.set(ch.name, set);
    }
    set.add(ch);
  }
  function unregisterChannel(ch) {
    const set = channelRegistry.get(ch.name);
    if (set) {
      set.delete(ch);
      if (set.size === 0)
        channelRegistry.delete(ch.name);
    }
  }

  class QBBroadcastChannel extends QBEventTarget {
    name;
    #closed = false;
    onmessage = null;
    onmessageerror = null;
    constructor(name) {
      super();
      this.name = name;
      registerChannel(this);
      beam.callSync("__broadcast_join", name);
    }
    postMessage(message) {
      if (this.#closed)
        throw new QBDOMException("BroadcastChannel is closed", "InvalidStateError");
      beam.call("__broadcast_post", this.name, structuredClone(message));
    }
    close() {
      if (this.#closed)
        return;
      this.#closed = true;
      unregisterChannel(this);
      beam.callSync("__broadcast_leave", this.name);
    }
    [SYM_RECEIVE](data) {
      if (this.#closed)
        return;
      const event = new QBMessageEvent("message", { data });
      this.onmessage?.(event);
      this.dispatchEvent(event);
    }
  }
  globalThis.BroadcastChannel = QBBroadcastChannel;
  globalThis.__qb_broadcast_dispatch = (channel, data) => {
    const set = channelRegistry.get(channel);
    if (!set)
      return;
    for (const ch of set)
      ch[SYM_RECEIVE](data);
  };

  // priv/ts/websocket.ts
  var SYM_HANDLE_EVENT = Symbol("handleEvent");

  class QBWebSocket extends QBEventTarget {
    static CONNECTING = 0;
    static OPEN = 1;
    static CLOSING = 2;
    static CLOSED = 3;
    CONNECTING = 0;
    OPEN = 1;
    CLOSING = 2;
    CLOSED = 3;
    url;
    extensions = "";
    #readyState = QBWebSocket.CONNECTING;
    #protocol = "";
    #binaryType = "blob";
    #bufferedAmount = 0;
    #id;
    onopen = null;
    onmessage = null;
    onclose = null;
    onerror = null;
    constructor(url, protocols) {
      super();
      this.url = url;
      const protoArray = protocols === undefined ? [] : typeof protocols === "string" ? [protocols] : protocols;
      this.#id = beam.callSync("__ws_connect", url, protoArray);
    }
    get readyState() {
      return this.#readyState;
    }
    get protocol() {
      return this.#protocol;
    }
    get binaryType() {
      return this.#binaryType;
    }
    set binaryType(value) {
      this.#binaryType = value;
    }
    get bufferedAmount() {
      return this.#bufferedAmount;
    }
    send(data) {
      if (this.#readyState === QBWebSocket.CONNECTING) {
        throw new QBDOMException("WebSocket is not open: readyState 0 (CONNECTING)", "InvalidStateError");
      }
      if (this.#readyState !== QBWebSocket.OPEN)
        return;
      let payload;
      if (typeof data === "string") {
        payload = data;
      } else if (data instanceof Uint8Array) {
        payload = data;
      } else if (data instanceof ArrayBuffer) {
        payload = new Uint8Array(data);
      } else if (data instanceof QBBlob) {
        payload = data[SYM_BYTES]();
      } else {
        payload = JSON.stringify(data);
      }
      beam.call("__ws_send", this.#id, payload);
    }
    close(code, reason) {
      if (this.#readyState === QBWebSocket.CLOSING || this.#readyState === QBWebSocket.CLOSED)
        return;
      if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
        throw new QBDOMException(`The code must be either 1000, or between 3000 and 4999. ${code} is neither.`, "InvalidAccessError");
      }
      this.#readyState = QBWebSocket.CLOSING;
      beam.call("__ws_close", this.#id, code ?? 1000, reason ?? "");
    }
    [SYM_HANDLE_EVENT](type, detail) {
      switch (type) {
        case "open":
          this.#readyState = QBWebSocket.OPEN;
          this.#protocol = detail?.protocol ?? "";
          {
            const ev = new QBEvent("open");
            this.onopen?.(ev);
            this.dispatchEvent(ev);
          }
          break;
        case "message": {
          let messageData = detail?.data;
          if (this.#binaryType === "arraybuffer" && messageData instanceof Uint8Array) {
            messageData = messageData.buffer;
          }
          const ev = new QBMessageEvent("message", { data: messageData });
          this.onmessage?.(ev);
          this.dispatchEvent(ev);
          break;
        }
        case "close": {
          this.#readyState = QBWebSocket.CLOSED;
          const ev = new QBCloseEvent("close", {
            code: detail?.code ?? 1006,
            reason: detail?.reason ?? "",
            wasClean: detail?.wasClean ?? false
          });
          this.onclose?.(ev);
          this.dispatchEvent(ev);
          break;
        }
        case "error": {
          const ev = new QBEvent("error");
          this.onerror?.(ev);
          this.dispatchEvent(ev);
          break;
        }
      }
    }
  }
  globalThis.WebSocket = QBWebSocket;
})();
