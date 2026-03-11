import { DOMException } from './dom-exception'

interface LockInfo {
  name: string
  mode: 'exclusive' | 'shared'
}

interface Lock {
  readonly name: string
  readonly mode: 'exclusive' | 'shared'
}

interface LockOptions {
  mode?: 'exclusive' | 'shared'
  ifAvailable?: boolean
  signal?: AbortSignal
}

interface LockManagerSnapshot {
  held: LockInfo[]
  pending: LockInfo[]
}

type LockGrantedCallback<T> = (lock: Lock | null) => T | Promise<T>

class LockManager {
  async request<T>(
    name: string,
    callbackOrOptions: LockOptions | LockGrantedCallback<T>,
    maybeCallback?: LockGrantedCallback<T>
  ): Promise<T> {
    let options: LockOptions = {}
    let callback: LockGrantedCallback<T>

    if (typeof callbackOrOptions === 'function') {
      callback = callbackOrOptions
    } else {
      options = callbackOrOptions
      if (!maybeCallback) throw new TypeError('callback is required')
      callback = maybeCallback
    }

    const mode = options.mode ?? 'exclusive'
    const ifAvailable = options.ifAvailable ?? false

    if (options.signal?.aborted) {
      throw new DOMException('The operation was aborted.', 'AbortError')
    }

    const result = await Beam.call('__locks_request', name, mode, ifAvailable)

    if (result === 'not_available') {
      return await callback(null)
    }

    if (result === 'holder_down') {
      throw new DOMException('Lock holder terminated', 'AbortError')
    }

    const lock: Lock = { name, mode }

    try {
      return await callback(lock)
    } finally {
      await Beam.call('__locks_release', name)
    }
  }

  async query(): Promise<LockManagerSnapshot> {
    return (await Beam.call('__locks_query')) as LockManagerSnapshot
  }
}

const lockManager = new LockManager()
const g = globalThis as Record<string, unknown>
g.navigator = g.navigator ?? {}
;(g.navigator as Record<string, unknown>).locks = lockManager
