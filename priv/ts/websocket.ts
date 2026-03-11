import { Blob, SYM_BYTES } from './blob'
import { DOMException } from './dom-exception'
import { Event, MessageEvent, CloseEvent } from './event'
import { EventTarget } from './event-target'

const SYM_HANDLE_EVENT = Symbol('handleEvent')

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
    this.url = url
    let protoArray: string[] = []
    if (typeof protocols === 'string') protoArray = [protocols]
    else if (protocols) protoArray = protocols
    this.#id = Beam.callSync('__ws_connect', url, protoArray) as string
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
    this.#binaryType = value
  }
  get bufferedAmount(): number {
    return this.#bufferedAmount
  }

  send(data: string | ArrayBuffer | Uint8Array | Blob): void {
    if (this.#readyState === WebSocket.CONNECTING) {
      throw new DOMException(
        'WebSocket is not open: readyState 0 (CONNECTING)',
        'InvalidStateError'
      )
    }
    if (this.#readyState !== WebSocket.OPEN) return

    let payload: string | Uint8Array
    if (typeof data === 'string') {
      payload = data
    } else if (data instanceof Uint8Array) {
      payload = data
    } else if (data instanceof ArrayBuffer) {
      payload = new Uint8Array(data)
    } else if (data instanceof Blob) {
      payload = data[SYM_BYTES]()
    } else {
      payload = JSON.stringify(data)
    }

    void Beam.call('__ws_send', this.#id, payload)
  }

  close(code?: number, reason?: string): void {
    if (this.#readyState === WebSocket.CLOSING || this.#readyState === WebSocket.CLOSED) return

    if (code !== undefined && code !== 1000 && (code < 3000 || code > 4999)) {
      throw new DOMException(
        `The code must be either 1000, or between 3000 and 4999. ${code} is neither.`,
        'InvalidAccessError'
      )
    }

    this.#readyState = WebSocket.CLOSING
    void Beam.call('__ws_close', this.#id, code ?? 1000, reason ?? '')
  }

  [SYM_HANDLE_EVENT](
    type: string,
    detail?: {
      data?: unknown
      code?: number
      reason?: string
      protocol?: string
      wasClean?: boolean
    }
  ): void {
    switch (type) {
      case 'open':
        this.#readyState = WebSocket.OPEN
        this.#protocol = detail?.protocol ?? ''
        {
          const ev = new Event('open')
          this.onopen?.(ev)
          this.dispatchEvent(ev)
        }
        break

      case 'message': {
        let messageData: unknown = detail?.data
        if (this.#binaryType === 'arraybuffer' && messageData instanceof Uint8Array) {
          messageData = messageData.buffer
        }
        const ev = new MessageEvent('message', { data: messageData })
        this.onmessage?.(ev)
        this.dispatchEvent(ev)
        break
      }

      case 'close': {
        this.#readyState = WebSocket.CLOSED
        const ev = new CloseEvent('close', {
          code: detail?.code ?? 1006,
          reason: detail?.reason ?? '',
          wasClean: detail?.wasClean ?? false
        })
        this.onclose?.(ev)
        this.dispatchEvent(ev)
        break
      }

      case 'error': {
        const ev = new Event('error')
        this.onerror?.(ev)
        this.dispatchEvent(ev)
        break
      }
    }
  }
}

export { WebSocket }
