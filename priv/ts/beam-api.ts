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

Beam.randomUUIDv7 = (): string =>
  Beam.callSync('__beam_random_uuid_v7') as string

Beam.deepEquals = (a: unknown, b: unknown): boolean => {
  return structuredClone(a) !== undefined && deepEqualsImpl(a, b)
}

function equalBytes(a: ArrayBufferView | ArrayBuffer, b: ArrayBufferView | ArrayBuffer): boolean {
  const left = a instanceof ArrayBuffer ? new Uint8Array(a) : new Uint8Array(a.buffer, a.byteOffset, a.byteLength)
  const right = b instanceof ArrayBuffer ? new Uint8Array(b) : new Uint8Array(b.buffer, b.byteOffset, b.byteLength)

  if (left.length !== right.length) return false
  for (let i = 0; i < left.length; i++) if (left[i] !== right[i]) return false
  return true
}

function equalArrays(a: unknown[], b: unknown[]): boolean {
  if (a.length !== b.length) return false
  for (let i = 0; i < a.length; i++) if (!deepEqualsImpl(a[i], b[i])) return false
  return true
}

function equalObjects(a: Record<string, unknown>, b: Record<string, unknown>): boolean {
  const ka = Object.keys(a).sort()
  const kb = Object.keys(b).sort()

  if (ka.length !== kb.length) return false
  for (let i = 0; i < ka.length; i++) {
    if (ka[i] !== kb[i]) return false
    if (!deepEqualsImpl(a[ka[i]], b[kb[i]])) return false
  }

  return true
}

function deepEqualsImpl(a: unknown, b: unknown): boolean {
  if (a === b) return true
  if (a === null || b === null) return false
  if (typeof a !== typeof b) return false
  if (a instanceof Date && b instanceof Date) return a.getTime() === b.getTime()
  if (a instanceof RegExp && b instanceof RegExp) return a.toString() === b.toString()
  if (a instanceof ArrayBuffer && b instanceof ArrayBuffer) return equalBytes(a, b)
  if (ArrayBuffer.isView(a) && ArrayBuffer.isView(b)) return equalBytes(a, b)
  if (Array.isArray(a) && Array.isArray(b)) return equalArrays(a, b)
  if (typeof a === 'object' && typeof b === 'object') {
    return equalObjects(a as Record<string, unknown>, b as Record<string, unknown>)
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

Beam.nanoseconds = (): number =>
  Beam.callSync('__beam_nanoseconds') as number

Beam.uniqueInteger = (): number =>
  Beam.callSync('__beam_unique_integer') as number

Beam.makeRef = (): BeamRef =>
  Beam.callSync('__beam_make_ref') as BeamRef

Beam.inspect = (value: unknown): string =>
  Beam.callSync('__beam_inspect', value) as string

Beam.nodes = (): string[] =>
  Beam.callSync('__beam_nodes') as string[]

Beam.rpc = (node: string, runtimeName: string, fnName: string, ...args: unknown[]): Promise<unknown> =>
  Beam.call('__beam_rpc', node, runtimeName, fnName, ...args)

Beam.spawn = (script: string): BeamPid =>
  Beam.callSync('__beam_spawn', script) as BeamPid

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

Beam.password = {
  hash: (password: string, options?: { iterations?: number }): Promise<string> =>
    Beam.call('__beam_password_hash', password, options?.iterations ?? 600000) as Promise<string>,
  verify: (password: string, hash: string): Promise<boolean> =>
    Beam.call('__beam_password_verify', password, hash) as Promise<boolean>,
}
