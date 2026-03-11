import { DOMException } from './dom-exception'
import { MessageEvent, ErrorEvent } from './event'
import { EventTarget } from './event-target'

type MessageHandler = ((event: { data: unknown }) => void) | null
type ErrorHandler = ((event: { message: string; error: unknown }) => void) | null

const workerRegistry = new Map<string, Worker>()

class Worker extends EventTarget {
  #pid: unknown
  #terminated = false
  #earlyMessages: unknown[] = []
  #onmessage: MessageHandler = null
  onerror: ErrorHandler = null

  constructor(script: string) {
    super()
    this.#pid = Beam.callSync('__worker_spawn', script)
    const pidKey = JSON.stringify(this.#pid)
    workerRegistry.set(pidKey, this)
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
    Beam.send(this.#pid, ['__worker_msg', data])
  }

  terminate(): void {
    if (this.#terminated) return
    this.#terminated = true
    const pidKey = JSON.stringify(this.#pid)
    workerRegistry.delete(pidKey)
    void Beam.call('__worker_terminate', this.#pid)
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
  const [type, pid, payload] = msg

  if (type !== '__worker_msg' && type !== '__worker_err') return false

  const pidKey = JSON.stringify(pid)
  const worker = workerRegistry.get(pidKey)
  if (!worker) return false

  if (type === '__worker_msg') {
    worker._dispatch(payload)
  } else {
    worker._error(String(payload), payload)
  }
  return true
})

export { Worker }
