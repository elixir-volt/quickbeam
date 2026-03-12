import { MessageEvent } from './event'
import { EventTarget } from './event-target'

type MessageHandler = ((ev: MessageEvent) => void) | null

class MessagePort extends EventTarget {
  #remote: MessagePort | null = null
  #closed = false
  #started = false
  #queue: unknown[] = []
  #onmessage: MessageHandler = null

  onmessageerror: MessageHandler = null

  get onmessage(): MessageHandler {
    return this.#onmessage
  }

  set onmessage(handler: MessageHandler) {
    this.#onmessage = handler
    if (handler !== null) this.start()
  }

  _pair(remote: MessagePort): void {
    this.#remote = remote
  }

  postMessage(data: unknown): void {
    if (this.#closed) return
    const remote = this.#remote
    if (!remote || remote.#closed) return

    const cloned = structuredClone(data)
    queueMicrotask(() => remote._deliver(cloned))
  }

  start(): void {
    if (this.#started) return
    this.#started = true
    const pending = this.#queue.splice(0)
    for (const data of pending) {
      queueMicrotask(() => this._dispatch(data))
    }
  }

  close(): void {
    this.#closed = true
    this.#queue.length = 0
  }

  _deliver(data: unknown): void {
    if (this.#closed) return
    if (!this.#started) {
      this.#queue.push(data)
      return
    }
    this._dispatch(data)
  }

  _dispatch(data: unknown): void {
    if (this.#closed) return
    const event = new MessageEvent('message', { data })
    this.#onmessage?.(event)
    this.dispatchEvent(event)
  }
}

class MessageChannel {
  readonly port1: MessagePort
  readonly port2: MessagePort

  constructor() {
    this.port1 = new MessagePort()
    this.port2 = new MessagePort()
    this.port1._pair(this.port2)
    this.port2._pair(this.port1)
  }
}

export { MessageChannel, MessagePort }
