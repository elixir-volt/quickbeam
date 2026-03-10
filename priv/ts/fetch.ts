import { QBBlob, SYM_BYTES } from "./blob";
import { QBReadableStream } from "./streams";
import { QBHeaders } from "./headers";
import type { QBHeadersInit } from "./headers";
import { QBAbortSignal } from "./abort";

type QBBodyInit = string | Uint8Array | ArrayBuffer | QBBlob | URLSearchParams | QBReadableStream;

interface QBRequestInit {
  method?: string;
  headers?: QBHeadersInit;
  body?: QBBodyInit | null;
  signal?: QBAbortSignal;
  redirect?: RequestRedirect;
}

async function bodyToBytes(body: QBBodyInit): Promise<{
  bytes: Uint8Array | null;
  contentType: string | null;
}> {
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
      contentType: "application/x-www-form-urlencoded;charset=UTF-8",
    };
  }
  if (body instanceof QBReadableStream) {
    const reader = (body as QBReadableStream<Uint8Array>).getReader();
    const chunks: Uint8Array[] = [];
    for (;;) {
      const { value, done } = await reader.read();
      if (done) break;
      chunks.push(value instanceof Uint8Array ? value : new Uint8Array(value as ArrayBuffer));
    }
    let total = 0;
    for (const c of chunks) total += c.length;
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

function buildRequestFromExisting(input: QBRequest, init?: QBRequestInit) {
  return {
    url: input.url,
    method: (init?.method ?? input.method).toUpperCase(),
    headers: new QBHeaders(init?.headers ?? (input.headers as unknown as QBHeadersInit)),
    body: init?.body !== undefined ? init.body : input.body,
    signal: init?.signal ?? input.signal,
    redirect: init?.redirect ?? input.redirect,
  };
}

function buildRequestFromURL(url: string, init?: QBRequestInit) {
  return {
    url,
    method: (init?.method ?? "GET").toUpperCase(),
    headers: new QBHeaders(init?.headers),
    body: init?.body ?? null,
    signal: init?.signal ?? new QBAbortSignal(),
    redirect: init?.redirect ?? "follow",
  };
}

class QBRequest {
  readonly url: string;
  readonly method: string;
  readonly headers: QBHeaders;
  readonly body: QBBodyInit | null;
  readonly signal: QBAbortSignal;
  readonly redirect: RequestRedirect;

  constructor(input: string | QBRequest, init?: QBRequestInit) {
    const props =
      input instanceof QBRequest
        ? buildRequestFromExisting(input, init)
        : buildRequestFromURL(input, init);

    this.url = props.url;
    this.method = props.method;
    this.headers = props.headers;
    this.body = props.body ?? null;
    this.signal = props.signal;
    this.redirect = props.redirect;
  }

  clone(): QBRequest {
    return new QBRequest(this);
  }
}

class QBResponse {
  readonly status: number;
  readonly statusText: string;
  readonly headers: QBHeaders;
  readonly url: string;
  readonly redirected: boolean;
  readonly type: ResponseType = "basic";
  #body: Uint8Array | null;
  #bodyUsed = false;

  constructor(
    body: Uint8Array | null,
    init: {
      status: number;
      statusText: string;
      headers: QBHeaders;
      url: string;
      redirected?: boolean;
    },
  ) {
    this.#body = body;
    this.status = init.status;
    this.statusText = init.statusText;
    this.headers = init.headers;
    this.url = init.url;
    this.redirected = init.redirected ?? false;
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300;
  }

  get bodyUsed(): boolean {
    return this.#bodyUsed;
  }

  get body(): QBReadableStream<Uint8Array> | null {
    if (this.#body === null) return null;
    const bytes = this.#body;
    return new QBReadableStream<Uint8Array>({
      start(controller) {
        if (bytes.length > 0) controller.enqueue(bytes);
        controller.close();
      },
    });
  }

  #consumeBody(): Uint8Array {
    if (this.#bodyUsed) throw new TypeError("Body already consumed");
    this.#bodyUsed = true;
    return this.#body ?? new Uint8Array(0);
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this.#consumeBody().buffer as ArrayBuffer;
  }

  async bytes(): Promise<Uint8Array> {
    return this.#consumeBody();
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this.#consumeBody());
  }

  async json(): Promise<unknown> {
    return JSON.parse(await this.text());
  }

  async blob(): Promise<QBBlob> {
    const bytes = this.#consumeBody();
    return new QBBlob([bytes], {
      type: this.headers.get("content-type") ?? "",
    });
  }

  clone(): QBResponse {
    if (this.#bodyUsed) throw new TypeError("Cannot clone a used response");
    return new QBResponse(this.#body ? this.#body.slice() : null, {
      status: this.status,
      statusText: this.statusText,
      headers: new QBHeaders(this.headers as unknown as QBHeadersInit),
      url: this.url,
      redirected: this.redirected,
    });
  }

  static error(): QBResponse {
    return new QBResponse(null, {
      status: 0,
      statusText: "",
      headers: new QBHeaders(),
      url: "",
    });
  }

  static redirect(url: string, status = 302): QBResponse {
    const headers = new QBHeaders([["location", url]]);
    return new QBResponse(null, { status, statusText: "", headers, url: "" });
  }

  static json(data: unknown, init?: { status?: number; headers?: QBHeadersInit }): QBResponse {
    const body = new TextEncoder().encode(JSON.stringify(data));
    const headers = new QBHeaders(init?.headers);
    if (!headers.has("content-type")) {
      headers.set("content-type", "application/json");
    }
    return new QBResponse(body, {
      status: init?.status ?? 200,
      statusText: "",
      headers,
      url: "",
    });
  }
}

interface FetchResult {
  status: number;
  statusText: string;
  headers: [string, string][];
  body: Uint8Array | null;
  url: string;
  redirected: boolean;
}

async function qbFetch(input: string | QBRequest, init?: QBRequestInit): Promise<QBResponse> {
  const request = input instanceof QBRequest ? input : new QBRequest(input, init);

  request.signal.throwIfAborted();

  let resolvedBody: Uint8Array | null = null;
  let bodyContentType: string | null = null;

  if (request.body !== null) {
    const { bytes, contentType } = await bodyToBytes(request.body);
    resolvedBody = bytes;
    bodyContentType = contentType;
  }

  if (bodyContentType && !request.headers.has("content-type")) {
    request.headers.set("content-type", bodyContentType);
  }

  const headerEntries: [string, string][] = [...request.headers.entries()];

  const payload = {
    url: request.url,
    method: request.method,
    headers: headerEntries,
    body: resolvedBody,
    redirect: request.redirect,
  };

  const resultPromise = beam.call("__fetch", payload) as Promise<FetchResult>;

  const abortPromise = new Promise<never>((_, reject) => {
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
    redirected: result.redirected,
  });
}

(globalThis as Record<string, unknown>).Request = QBRequest;
(globalThis as Record<string, unknown>).Response = QBResponse;
(globalThis as Record<string, unknown>).fetch = qbFetch;
