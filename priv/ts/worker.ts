import { DOMException } from './dom-exception'
import { MessageEvent, ErrorEvent } from './event'
import { EventTarget } from './event-target'

type MessageHandler = ((event: { data: unknown }) => void) | null
type ErrorHandler = ((event: { message: string; error: unknown }) => void) | null

const workerRegistry = new Map<number, Worker>()

class Worker extends EventTarget {
  #id: number
  #terminated = false
  #earlyMessages: unknown[] = []
  #onmessage: MessageHandler = null
  onerror: ErrorHandler = null

  constructor(script: string) {
    super()
    this.#id = Beam.callSync('__worker_spawn', script) as number
    workerRegistry.set(this.#id, this)
  }

  get onmessage(): MessageHandler {
    return this.#onmessage
  }

  set onmessage(handler: MessageHandler) {
    this.#onmessage = handler
    if (handler && this.#earlyMessages.length > 0) {
      const queued = this.#earlyMessages.splice(0)
      for (const data of queued) {
        this._dispatch(data)
      }
    }
  }

  postMessage(data: unknown): void {
    if (this.#terminated) throw new DOMException('Worker has been terminated', 'InvalidStateError')
    Beam.callSync('__worker_post_to_child', this.#id, data)
  }

  terminate(): void {
    if (this.#terminated) return
    this.#terminated = true
    workerRegistry.delete(this.#id)
    void Beam.call('__worker_terminate', this.#id)
  }

  _dispatch(data: unknown): void {
    if (!this.#onmessage) {
      this.#earlyMessages.push(data)
      return
    }
    const event = new MessageEvent('message', { data })
    this.dispatchEvent(event)
    this.#onmessage({ data })
  }

  _error(message: string, error: unknown): void {
    const event = new ErrorEvent('error', { message })
    this.dispatchEvent(event)
    this.onerror?.({ message, error })
  }
}

declare const __qb_register_dispatcher: (fn: (msg: unknown) => boolean) => void

__qb_register_dispatcher((msg: unknown): boolean => {
  if (!Array.isArray(msg) || msg.length < 3) return false
  const [type, id, payload] = msg

  if (type !== '__worker_msg' && type !== '__worker_err') return false
  if (typeof id !== 'number') return false

  const worker = workerRegistry.get(id)
  if (!worker) return false

  if (type === '__worker_msg') {
    worker._dispatch(payload)
  } else {
    worker._error(String(payload), payload)
  }
  return true
})

export { Worker }
