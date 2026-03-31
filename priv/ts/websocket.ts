import { Blob, SYM_BYTES } from './blob'
import { DOMException } from './dom-exception'
import { Event, MessageEvent, CloseEvent, ErrorEvent } from './event'
import { EventTarget } from './event-target'

const websocketRegistry = new Map<string, WebSocket>()
const PROTOCOL_RE = /^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$/

function normalizeWebSocketURL(input: string): string {
  let parsed: URL

  try {
    parsed = new URL(input)
  } catch {
    throw new DOMException('The URL is invalid.', 'SyntaxError')
  }

  if (parsed.hash !== '') {
    throw new DOMException('The URL contains a fragment identifier.', 'SyntaxError')
  }

  if (parsed.protocol === 'http:') parsed.protocol = 'ws:'
  if (parsed.protocol === 'https:') parsed.protocol = 'wss:'

  if (parsed.protocol !== 'ws:' && parsed.protocol !== 'wss:') {
    throw new DOMException('The URL scheme must be ws, wss, http, or https.', 'SyntaxError')
  }

  return parsed.href
}

function normalizeProtocols(protocols?: string | string[]): string[] {
  const values = typeof protocols === 'string' ? [protocols] : [...(protocols ?? [])]
  const seen = new Set<string>()

  for (const protocol of values) {
    if (!PROTOCOL_RE.test(protocol)) {
      throw new DOMException('The subprotocol is invalid.', 'SyntaxError')
    }

    const lower = protocol.toLowerCase()
    if (seen.has(lower)) {
      throw new DOMException('The subprotocol list contains duplicates.', 'SyntaxError')
    }

    seen.add(lower)
  }

  return values
}

function isArrayBufferView(value: unknown): value is ArrayBufferView {
  return ArrayBuffer.isView(value)
}

function arrayBufferFrom(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) as ArrayBuffer
}

class WebSocket extends EventTarget {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3

  readonly CONNECTING = 0
  readonly OPEN = 1
  readonly CLOSING = 2
  readonly CLOSED = 3

  readonly url: string
  readonly extensions = ''
  #readyState = WebSocket.CONNECTING
  #protocol = ''
  #binaryType: BinaryType = 'blob'
  #bufferedAmount = 0
  #id: string

  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onclose: ((ev: CloseEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null

  constructor(url: string, protocols?: string | string[]) {
    super()
    const normalizedUrl = normalizeWebSocketURL(url)
    const normalizedProtocols = normalizeProtocols(protocols)

    this.url = normalizedUrl
    this.#id = Beam.callSync('__ws_connect', normalizedUrl, normalizedProtocols) as string
    websocketRegistry.set(this.#id, this)
  }

  get readyState(): number {
    return this.#readyState
  }

  get protocol(): string {
    return this.#protocol
  }

  get binaryType(): BinaryType {
    return this.#binaryType
  }

  set binaryType(value: BinaryType) {
    if (value === 'blob' || value === 'arraybuffer') {
      this.#binaryType = value
    }
  }

  get bufferedAmount(): number {
    return this.#bufferedAmount
  }

  send(data: string | BufferSource | Blob): void {
    if (this.#readyState === WebSocket.CONNECTING) {
      throw new DOMException(
        'WebSocket is not open: readyState 0 (CONNECTING)',
        'InvalidStateError'
      )
    }

    if (this.#readyState !== WebSocket.OPEN) return

    let payload: ['text', string] | ['binary', Uint8Array]
    let size = 0

    if (typeof data === 'string') {
      payload = ['text', data]
      size = new TextEncoder().encode(data).byteLength
    } else if (data instanceof Blob) {
      const bytes = data[SYM_BYTES]()
      payload = ['binary', bytes]
      size = bytes.byteLength
    } else if (data instanceof ArrayBuffer) {
      const bytes = new Uint8Array(data)
      payload = ['binary', bytes]
      size = bytes.byteLength
    } else if (isArrayBufferView(data)) {
      const bytes = new Uint8Array(data.buffer, data.byteOffset, data.byteLength)
      payload = ['binary', bytes]
      size = bytes.byteLength
    } else {
      throw new TypeError('WebSocket.send requires a string, Blob, ArrayBuffer, or ArrayBufferView')
    }

    this.#bufferedAmount += size
    queueMicrotask(() => {
      this.#bufferedAmount = Math.max(0, this.#bufferedAmount - size)
    })

    void Beam.call('__ws_send', this.#id, payload)
  }

  close(code?: number, reason?: string): void {
    if (this.#readyState === WebSocket.CLOSING || this.#readyState === WebSocket.CLOSED) return

    if (code === undefined && reason !== undefined) {
      throw new DOMException(
        'A close reason may only be given if a code is also supplied.',
        'InvalidAccessError'
      )
    }

    if (code !== undefined) {
      if (!Number.isInteger(code)) {
        throw new DOMException('The close code must be an integer.', 'InvalidAccessError')
      }

      if (code !== 1000 && (code < 3000 || code > 4999)) {
        throw new DOMException(
          `The code must be either 1000, or between 3000 and 4999. ${code} is neither.`,
          'InvalidAccessError'
        )
      }
    }

    if (reason !== undefined && new TextEncoder().encode(reason).byteLength > 123) {
      throw new DOMException('The close reason must not be greater than 123 bytes.', 'SyntaxError')
    }

    this.#readyState = WebSocket.CLOSING
    void Beam.call('__ws_close', this.#id, code ?? 1000, reason ?? '')
  }

  _onOpen(protocol: string): void {
    this.#readyState = WebSocket.OPEN
    this.#protocol = protocol
    const event = new Event('open')
    this.dispatchEvent(event)
    this.onopen?.(event)
  }

  _onMessage(data: unknown): void {
    let messageData = data

    if (data instanceof Uint8Array) {
      messageData =
        this.#binaryType === 'arraybuffer' ? arrayBufferFrom(data) : new Blob([data])
    }

    const event = new MessageEvent('message', { data: messageData })
    this.dispatchEvent(event)
    this.onmessage?.(event)
  }

  _onError(reason: string): void {
    const event = new ErrorEvent('error', { message: reason })
    this.dispatchEvent(event)
    this.onerror?.(event)
  }

  _onClose(code: number, reason: string, wasClean: boolean): void {
    this.#readyState = WebSocket.CLOSED
    websocketRegistry.delete(this.#id)
    const event = new CloseEvent('close', { code, reason, wasClean })
    this.dispatchEvent(event)
    this.onclose?.(event)
  }
}

declare const __qb_register_dispatcher: (fn: (msg: unknown) => boolean) => void

__qb_register_dispatcher((msg: unknown): boolean => {
  if (!Array.isArray(msg) || msg.length < 3) return false

  const [type, id, ...rest] = msg
  if (typeof id !== 'string') return false

  const websocket = websocketRegistry.get(id)
  if (!websocket) return false

  switch (type) {
    case '__ws_open':
      websocket._onOpen((rest[0] as string) ?? '')
      return true

    case '__ws_message':
      websocket._onMessage(rest[0])
      return true

    case '__ws_error':
      websocket._onError(String(rest[0] ?? 'WebSocket error'))
      return true

    case '__ws_close':
      websocket._onClose(
        typeof rest[0] === 'number' ? rest[0] : 1006,
        typeof rest[1] === 'string' ? rest[1] : '',
        rest[2] === true
      )
      return true

    default:
      return false
  }
})

export { WebSocket }
