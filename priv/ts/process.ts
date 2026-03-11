const monitorCallbacks = new Map<number, (reason: unknown) => void>()
let monitorIdCounter = 0
let userMessageHandler: ((msg: unknown) => void) | null = null

const originalOnMessage = Beam.onMessage.bind(Beam)

Beam.monitor = (pid: BeamPid, callback: (reason: unknown) => void): BeamRef => {
  const id = ++monitorIdCounter
  monitorCallbacks.set(id, callback)
  const ref = Beam.callSync('__process_monitor', pid, id) as BeamRef
  return ref
}

Beam.demonitor = (ref: BeamRef): void => {
  const id = Beam.callSync('__process_demonitor', ref) as number
  if (typeof id === 'number') {
    monitorCallbacks.delete(id)
  }
}

Beam.onMessage = (handler: (msg: unknown) => void): void => {
  if (typeof handler !== 'function') {
    throw new TypeError('Beam.onMessage requires a function argument')
  }
  userMessageHandler = handler
}

type InternalDispatcher = (msg: unknown) => boolean
const internalDispatchers: InternalDispatcher[] = []

;(globalThis as Record<string, unknown>).__qb_register_dispatcher = (fn: InternalDispatcher) => {
  internalDispatchers.push(fn)
}

originalOnMessage((msg: unknown) => {
  if (Array.isArray(msg) && msg.length === 3 && msg[0] === '__qb_down') {
    const [, id, reason] = msg
    const cb = monitorCallbacks.get(id as number)
    if (cb) {
      monitorCallbacks.delete(id as number)
      cb(reason)
    }
    return
  }

  for (const dispatcher of internalDispatchers) {
    if (dispatcher(msg)) return
  }

  if (userMessageHandler) {
    userMessageHandler(msg)
  }
})
