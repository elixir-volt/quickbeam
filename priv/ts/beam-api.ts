let _version: string | undefined

Object.defineProperty(Beam, 'version', {
  get() {
    return (_version ??= Beam.callSync('__beam_version') as string)
  },
  enumerable: true,
})

Beam.sleep = (ms: number): Promise<void> =>
  new Promise(resolve => setTimeout(resolve, ms))

Beam.sleepSync = (ms: number): void => {
  Beam.callSync('__beam_sleep_sync', ms)
}

Beam.hash = (data: unknown, range?: number): number => {
  if (range !== undefined) return Beam.callSync('__beam_hash', data, range) as number
  return Beam.callSync('__beam_hash', data) as number
}

Beam.escapeHTML = (str: string): string => {
  if (typeof str !== 'string') str = String(str)
  return Beam.callSync('__beam_escape_html', str) as string
}

Beam.which = (bin: string): string | null =>
  Beam.callSync('__beam_which', bin) as string | null

const PEEK_PENDING = Symbol('peek_pending')

Beam.peek = Object.assign(
  (promise: unknown): unknown => {
    if (!(promise instanceof Promise)) return promise
    let value: unknown = PEEK_PENDING
    let error: unknown = PEEK_PENDING
    // Attach handlers — they'll resolve during the same job drain if already settled
    promise.then(v => { value = v }, r => { error = r })
    // Force a microtask flush by awaiting an already-resolved promise
    // This only works within QuickBEAM's eval loop which drains jobs
    if (value !== PEEK_PENDING) return value
    if (error !== PEEK_PENDING) return error
    return promise
  },
  {
    status(promise: unknown): 'fulfilled' | 'rejected' | 'pending' {
      if (!(promise instanceof Promise)) return 'fulfilled'
      let value: unknown = PEEK_PENDING
      let error: unknown = PEEK_PENDING
      promise.then(() => { value = true }, () => { error = true })
      if (value !== PEEK_PENDING) return 'fulfilled'
      if (error !== PEEK_PENDING) return 'rejected'
      return 'pending'
    },
  }
)

Beam.randomUUIDv7 = (): string =>
  Beam.callSync('__beam_random_uuid_v7') as string

Beam.deepEquals = (a: unknown, b: unknown): boolean => {
  return structuredClone(a) !== undefined && deepEqualsImpl(a, b)
}

function deepEqualsImpl(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (a === null || b === null) return false
  if (typeof a !== typeof b) return false

  if (a instanceof Date && b instanceof Date) return a.getTime() === b.getTime()
  if (a instanceof RegExp && b instanceof RegExp) return a.toString() === b.toString()

  if (a instanceof ArrayBuffer && b instanceof ArrayBuffer) {
    if (a.byteLength !== b.byteLength) return false
    const va = new Uint8Array(a), vb = new Uint8Array(b)
    for (let i = 0; i < va.length; i++) if (va[i] !== vb[i]) return false
    return true
  }

  if (ArrayBuffer.isView(a) && ArrayBuffer.isView(b)) {
    const ta = a as Uint8Array, tb = b as Uint8Array
    if (ta.length !== tb.length) return false
    for (let i = 0; i < ta.length; i++) if (ta[i] !== tb[i]) return false
    return true
  }

  if (Array.isArray(a) && Array.isArray(b)) {
    if (a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (!deepEqualsImpl(a[i], b[i])) return false
    return true
  }

  if (typeof a === 'object' && typeof b === 'object') {
    const ka = Object.keys(a as object).sort()
    const kb = Object.keys(b as object).sort()
    if (ka.length !== kb.length) return false
    for (let i = 0; i < ka.length; i++) {
      if (ka[i] !== kb[i]) return false
      if (!deepEqualsImpl((a as Record<string, unknown>)[ka[i]], (b as Record<string, unknown>)[kb[i]])) return false
    }
    return true
  }

  return false
}

Beam.semver = {
  satisfies(version: string, range: string): boolean {
    return Beam.callSync('__beam_semver_satisfies', version, range) as boolean
  },
  order(a: string, b: string): -1 | 0 | 1 | null {
    return Beam.callSync('__beam_semver_order', a, b) as -1 | 0 | 1 | null
  },
}

Beam.nodes = (): string[] =>
  Beam.callSync('__beam_nodes') as string[]

Beam.rpc = (node: string, runtimeName: string, fnName: string, ...args: unknown[]): Promise<unknown> =>
  Beam.call('__beam_rpc', node, runtimeName, fnName, ...args)

Beam.spawn = (script: string): unknown =>
  Beam.callSync('__beam_spawn', script)

Beam.register = (name: string): boolean =>
  Beam.callSync('__beam_register', name) as boolean

Beam.whereis = (name: string): BeamPid | null =>
  Beam.callSync('__beam_whereis', name) as BeamPid | null

Beam.link = (pid: BeamPid): boolean =>
  Beam.callSync('__beam_link', pid) as boolean

Beam.unlink = (pid: BeamPid): boolean =>
  Beam.callSync('__beam_unlink', pid) as boolean

Beam.systemInfo = (): Record<string, unknown> =>
  Beam.callSync('__beam_system_info') as Record<string, unknown>

Beam.processInfo = (): Record<string, unknown> | null =>
  Beam.callSync('__beam_process_info') as Record<string, unknown> | null
