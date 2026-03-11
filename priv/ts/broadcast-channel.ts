import { DOMException } from './dom-exception'
import { MessageEvent } from './event'
import { EventTarget } from './event-target'

const SYM_RECEIVE = Symbol('receive')

const channelRegistry = new Map<string, Set<BroadcastChannel>>()

class BroadcastChannel extends EventTarget {
  readonly name: string
  #closed = false

  onmessage: ((ev: MessageEvent) => void) | null = null
  onmessageerror: ((ev: MessageEvent) => void) | null = null

  constructor(name: string) {
    super()
    this.name = name
    let set = channelRegistry.get(name)
    if (!set) {
      set = new Set()
      channelRegistry.set(name, set)
    }
    set.add(this)
    Beam.callSync('__broadcast_join', name)
  }

  postMessage(message: unknown): void {
    if (this.#closed) throw new DOMException('BroadcastChannel is closed', 'InvalidStateError')
    void Beam.call('__broadcast_post', this.name, structuredClone(message))
  }

  close(): void {
    if (this.#closed) return
    this.#closed = true
    const set = channelRegistry.get(this.name)
    if (set) {
      set.delete(this)
      if (set.size === 0) channelRegistry.delete(this.name)
    }
    Beam.callSync('__broadcast_leave', this.name)
  }

  [SYM_RECEIVE](data: unknown): void {
    if (this.#closed) return
    const event = new MessageEvent('message', { data })
    this.onmessage?.(event)
    this.dispatchEvent(event)
  }
}

;(globalThis as Record<string, unknown>).__qb_broadcast_dispatch = (
  channel: string,
  data: unknown
) => {
  const set = channelRegistry.get(channel)
  if (!set) return
  for (const ch of set) ch[SYM_RECEIVE](data)
}

export { BroadcastChannel }
