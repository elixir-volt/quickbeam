const env = new Proxy({} as Record<string, string | undefined>, {
  get(_target, prop: string) {
    if (typeof prop !== 'string') return undefined
    return Beam.callSync('__process_env_get', prop) as string | undefined
  },
  set(_target, prop: string, value: string) {
    Beam.callSync('__process_env_set', prop, String(value))
    return true
  },
  deleteProperty(_target, prop: string) {
    Beam.callSync('__process_env_delete', prop)
    return true
  },
  has(_target, prop: string) {
    return Beam.callSync('__process_env_get', prop) !== null
  },
  ownKeys() {
    return Beam.callSync('__process_env_keys') as string[]
  },
  getOwnPropertyDescriptor(_target, prop: string) {
    const val = Beam.callSync('__process_env_get', prop) as string | undefined
    if (val === undefined) return undefined
    return { value: val, writable: true, enumerable: true, configurable: true }
  },
})

let qbProcessPlatform: string | undefined
let qbProcessArch: string | undefined
let qbProcessPid: number | undefined

const qbProcess = {
  env,
  argv: ['beam', 'quickbeam'],
  version: 'v22.0.0',
  versions: {
    node: '22.0.0',
    quickbeam: '0.2.0',
  },
  get platform() {
    return (qbProcessPlatform ??= Beam.callSync('__process_platform') as string)
  },
  get arch() {
    return (qbProcessArch ??= Beam.callSync('__process_arch') as string)
  },
  get pid() {
    return (qbProcessPid ??= Beam.callSync('__process_pid') as number)
  },
  cwd() {
    return Beam.callSync('__process_cwd') as string
  },
  exit(code = 0) {
    throw new Error(`process.exit(${code})`)
  },
  nextTick(callback: (...args: unknown[]) => void, ...args: unknown[]) {
    queueMicrotask(() => callback(...args))
  },
  hrtime: Object.assign(
    function hrtime(prev?: [number, number]): [number, number] {
      const now = performance.now()
      const sec = Math.floor(now / 1000)
      const nsec = Math.round((now % 1000) * 1e6)
      if (!prev) return [sec, nsec]
      let ds = sec - prev[0]
      let dn = nsec - prev[1]
      if (dn < 0) { ds--; dn += 1e9 }
      return [ds, dn]
    },
    {
      bigint(): bigint {
        return BigInt(Math.round(performance.now() * 1e6))
      },
    }
  ),
  stdout: {
    write(data: string) {
      Beam.callSync('__console_write', 'info', data)
      return true
    },
    isTTY: false,
  },
  stderr: {
    write(data: string) {
      Beam.callSync('__console_write', 'error', data)
      return true
    },
    isTTY: false,
  },
};

;(globalThis as Record<string, unknown>).process = qbProcess
