import { AbortSignal } from './abort'
import { Blob, SYM_BYTES } from './blob'
import { Headers } from './headers'
import { ReadableStream } from './streams'

import type { HeadersInit } from './headers'

type BodyInit = string | Uint8Array | ArrayBuffer | Blob | URLSearchParams | ReadableStream

interface RequestInit {
  method?: string
  headers?: HeadersInit
  body?: BodyInit | null
  signal?: AbortSignal
  redirect?: RequestRedirect
}

async function bodyToBytes(body: BodyInit): Promise<{
  bytes: Uint8Array | null
  contentType: string | null
}> {
  if (typeof body === 'string') {
    return { bytes: new TextEncoder().encode(body), contentType: 'text/plain;charset=UTF-8' }
  }
  if (body instanceof Uint8Array) {
    return { bytes: body, contentType: null }
  }
  if (body instanceof ArrayBuffer) {
    return { bytes: new Uint8Array(body), contentType: null }
  }
  if (body instanceof Blob) {
    return { bytes: body[SYM_BYTES](), contentType: body.type || null }
  }
  if (body instanceof URLSearchParams) {
    return {
      bytes: new TextEncoder().encode(body.toString()),
      contentType: 'application/x-www-form-urlencoded;charset=UTF-8'
    }
  }
  if (body instanceof ReadableStream) {
    const reader = (body as ReadableStream<Uint8Array>).getReader()
    const chunks: Uint8Array[] = []
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      chunks.push(value instanceof Uint8Array ? value : new Uint8Array(value as ArrayBuffer))
    }
    let total = 0
    for (const c of chunks) total += c.length
    const result = new Uint8Array(total)
    let offset = 0
    for (const c of chunks) {
      result.set(c, offset)
      offset += c.length
    }
    return { bytes: result, contentType: null }
  }
  return { bytes: null, contentType: null }
}

class Request {
  readonly url: string
  readonly method: string
  readonly headers: Headers
  readonly body: BodyInit | null
  readonly signal: AbortSignal
  readonly redirect: RequestRedirect

  constructor(input: string | Request, init?: RequestInit) {
    const isClone = input instanceof Request
    this.url = isClone ? input.url : input
    this.method = (init?.method ?? (isClone ? input.method : 'GET')).toUpperCase()
    this.headers = new Headers(
      init?.headers ?? (isClone ? (input.headers as unknown as HeadersInit) : undefined)
    )
    if (init?.body !== undefined) this.body = init.body
    else this.body = isClone ? input.body : null
    this.signal = init?.signal ?? (isClone ? input.signal : new AbortSignal())
    this.redirect = init?.redirect ?? (isClone ? input.redirect : 'follow')
  }

  clone(): Request {
    return new Request(this)
  }
}

class Response {
  readonly status: number
  readonly statusText: string
  readonly headers: Headers
  readonly url: string
  readonly redirected: boolean
  readonly type: ResponseType = 'basic'
  #body: Uint8Array | null
  #bodyUsed = false

  constructor(
    body: Uint8Array | null,
    init: {
      status: number
      statusText: string
      headers: Headers
      url: string
      redirected?: boolean
    }
  ) {
    this.#body = body
    this.status = init.status
    this.statusText = init.statusText
    this.headers = init.headers
    this.url = init.url
    this.redirected = init.redirected ?? false
  }

  get ok(): boolean {
    return this.status >= 200 && this.status < 300
  }

  get bodyUsed(): boolean {
    return this.#bodyUsed
  }

  get body(): ReadableStream<Uint8Array> | null {
    if (this.#body === null) return null
    const bytes = this.#body
    return new ReadableStream<Uint8Array>({
      start(controller) {
        if (bytes.length > 0) controller.enqueue(bytes)
        controller.close()
      }
    })
  }

  #consumeBody(): Uint8Array {
    if (this.#bodyUsed) throw new TypeError('Body already consumed')
    this.#bodyUsed = true
    return this.#body ?? new Uint8Array(0)
  }

  async arrayBuffer(): Promise<ArrayBuffer> {
    return this.#consumeBody().buffer as ArrayBuffer
  }

  async bytes(): Promise<Uint8Array> {
    return this.#consumeBody()
  }

  async text(): Promise<string> {
    return new TextDecoder().decode(this.#consumeBody())
  }

  async json(): Promise<unknown> {
    return JSON.parse(await this.text())
  }

  async blob(): Promise<Blob> {
    const bytes = this.#consumeBody()
    return new Blob([bytes], { type: this.headers.get('content-type') ?? '' })
  }

  clone(): Response {
    if (this.#bodyUsed) throw new TypeError('Cannot clone a used response')
    return new Response(this.#body ? this.#body.slice() : null, {
      status: this.status,
      statusText: this.statusText,
      headers: new Headers(this.headers as unknown as HeadersInit),
      url: this.url,
      redirected: this.redirected
    })
  }

  static error(): Response {
    return new Response(null, {
      status: 0,
      statusText: '',
      headers: new Headers(),
      url: ''
    })
  }

  static redirect(url: string, status = 302): Response {
    const headers = new Headers([['location', url]])
    return new Response(null, { status, statusText: '', headers, url: '' })
  }

  static json(data: unknown, init?: { status?: number; headers?: HeadersInit }): Response {
    const body = new TextEncoder().encode(JSON.stringify(data))
    const headers = new Headers(init?.headers)
    if (!headers.has('content-type')) {
      headers.set('content-type', 'application/json')
    }
    return new Response(body, { status: init?.status ?? 200, statusText: '', headers, url: '' })
  }
}

interface FetchResult {
  status: number
  statusText: string
  headers: [string, string][]
  body: Uint8Array | null
  url: string
  redirected: boolean
}

async function fetchImpl(input: string | Request, init?: RequestInit): Promise<Response> {
  const request = input instanceof Request ? input : new Request(input, init)

  request.signal.throwIfAborted()

  let resolvedBody: Uint8Array | null = null
  let bodyContentType: string | null = null

  if (request.body !== null) {
    const { bytes, contentType } = await bodyToBytes(request.body)
    resolvedBody = bytes
    bodyContentType = contentType
  }

  if (bodyContentType && !request.headers.has('content-type')) {
    request.headers.set('content-type', bodyContentType)
  }

  const payload = {
    url: request.url,
    method: request.method,
    headers: [...request.headers.entries()] as [string, string][],
    body: resolvedBody,
    redirect: request.redirect
  }

  const resultPromise = Beam.call('__fetch', payload) as Promise<FetchResult>

  const abortPromise = new Promise<never>((_, reject) => {
    if (request.signal.aborted) {
      reject(request.signal.reason)
      return
    }
    request.signal.addEventListener('abort', () => reject(request.signal.reason), { once: true })
  })

  const result = await Promise.race([resultPromise, abortPromise])

  return new Response(result.body instanceof Uint8Array ? result.body : null, {
    status: result.status,
    statusText: result.statusText,
    headers: new Headers(result.headers),
    url: result.url || request.url,
    redirected: result.redirected
  })
}

export { Request, Response, fetchImpl as fetch }
