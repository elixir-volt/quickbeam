import { Event, MessageEvent, ErrorEvent } from './event'
import { EventTarget } from './event-target'

type EventSourceState = 0 | 1 | 2

const eventSourceRegistry = new Map<string, EventSource>()

class EventSource extends EventTarget {
  static readonly CONNECTING: EventSourceState = 0
  static readonly OPEN: EventSourceState = 1
  static readonly CLOSED: EventSourceState = 2

  readonly CONNECTING: EventSourceState = 0
  readonly OPEN: EventSourceState = 1
  readonly CLOSED: EventSourceState = 2

  readonly url: string
  readonly withCredentials = false
  readyState: EventSourceState = 0

  onopen: ((event: Event) => void) | null = null
  onmessage: ((event: MessageEvent) => void) | null = null
  onerror: ((event: Event) => void) | null = null

  #taskPid: unknown = null
  #id: string
  #lastEventId = ''

  constructor(url: string) {
    super()
    this.url = url
    this.#id = String(Math.random()).slice(2)
    eventSourceRegistry.set(this.#id, this)
    this.#taskPid = Beam.callSync('__eventsource_open', url, this.#id)
  }

  get lastEventId(): string {
    return this.#lastEventId
  }

  close(): void {
    if (this.readyState === 2) return
    this.readyState = 2
    eventSourceRegistry.delete(this.#id)
    if (this.#taskPid) {
      void Beam.call('__eventsource_close', this.#taskPid)
    }
  }

  _onOpen(): void {
    this.readyState = 1
    const event = new Event('open')
    this.dispatchEvent(event)
    this.onopen?.(event)
  }

  _onEvent(type: string, data: string, id: string | null): void {
    if (id !== null) this.#lastEventId = id
    const event = new MessageEvent(type, { data, lastEventId: this.#lastEventId })
    this.dispatchEvent(event)
    if (type === 'message') {
      this.onmessage?.(event)
    }
  }

  _onError(reason: string): void {
    this.readyState = 2
    const event = new ErrorEvent('error', { message: reason })
    this.dispatchEvent(event)
    this.onerror?.(event)
  }
}

declare const __qb_register_dispatcher: (fn: (msg: unknown) => boolean) => void

__qb_register_dispatcher((msg: unknown): boolean => {
  if (!Array.isArray(msg)) return false
  const [type, id, ...rest] = msg

  if (typeof id !== 'string') return false
  const source = eventSourceRegistry.get(id)
  if (!source) return false

  if (type === '__eventsource_open') {
    source._onOpen()
    return true
  }
  if (type === '__eventsource_event') {
    const [eventType, data, eventId] = rest
    source._onEvent(eventType as string, data as string, eventId as string | null)
    return true
  }
  if (type === '__eventsource_error') {
    source._onError(rest[0] as string)
    return true
  }
  return false
})

export { EventSource }
