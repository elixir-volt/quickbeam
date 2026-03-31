class WasmCompileError extends Error {
  constructor(message?: string) { super(message); this.name = 'CompileError' }
}

class WasmLinkError extends Error {
  constructor(message?: string) { super(message); this.name = 'LinkError' }
}

class WasmRuntimeError extends Error {
  constructor(message?: string) { super(message); this.name = 'RuntimeError' }
}

type WasmModuleHandle = unknown
type WasmInstanceHandle = unknown

interface ImportObject {
  [module: string]: { [name: string]: Function | WasmMemory | WasmTable | WasmGlobal }
}

interface ExportInfo { name: string; kind: string }
interface ImportInfo { module: string; name: string; kind: string }

class WasmModule {
  /** @internal */
  _handle: WasmModuleHandle

  constructor(bufferSource: BufferSource) {
    const bytes = toUint8Array(bufferSource)
    const result = Beam.callSync('__wasm_compile', bytes) as { ok: WasmModuleHandle; error?: string }
    if (result.error) throw new WasmCompileError(result.error)
    this._handle = result.ok
  }

  static exports(module: WasmModule): ExportInfo[] {
    return Beam.callSync('__wasm_module_exports', module._handle) as ExportInfo[]
  }

  static imports(module: WasmModule): ImportInfo[] {
    return Beam.callSync('__wasm_module_imports', module._handle) as ImportInfo[]
  }

  static customSections(_module: WasmModule, _sectionName: string): ArrayBuffer[] {
    return []
  }
}

class WasmInstance {
  exports: Record<string, Function | WasmMemory | WasmTable | WasmGlobal>
  /** @internal */
  _handle: WasmInstanceHandle

  constructor(module: WasmModule, _importObject?: ImportObject) {
    const result = Beam.callSync('__wasm_start', module._handle) as { ok: WasmInstanceHandle; error?: string }
    if (result.error) throw new WasmLinkError(result.error)
    this._handle = result.ok

    const exportList = Beam.callSync('__wasm_module_exports', module._handle) as ExportInfo[]
    this.exports = buildExports(this._handle, exportList)
  }
}

class WasmMemory {
  /** @internal */
  _buffer: ArrayBuffer | null = null

  constructor(descriptor: { initial: number; maximum?: number; shared?: boolean }) {
    // Standalone memory — not yet backed by an instance
    this._buffer = new ArrayBuffer(descriptor.initial * 65536)
  }

  get buffer(): ArrayBuffer {
    return this._buffer!
  }

  grow(delta: number): number {
    const oldPages = this._buffer!.byteLength / 65536
    const newBuffer = new ArrayBuffer((oldPages + delta) * 65536)
    new Uint8Array(newBuffer).set(new Uint8Array(this._buffer!))
    this._buffer = newBuffer
    return oldPages
  }
}

class WasmTable {
  /** @internal */
  _entries: (Function | null)[]
  readonly length: number

  constructor(descriptor: { element: string; initial: number; maximum?: number }) {
    this._entries = new Array(descriptor.initial).fill(null)
    this.length = descriptor.initial
  }

  get(index: number): Function | null { return this._entries[index] ?? null }
  set(index: number, value: Function | null): void { this._entries[index] = value }
  grow(delta: number): number {
    const old = this._entries.length
    for (let i = 0; i < delta; i++) this._entries.push(null)
    return old
  }
}

class WasmGlobal {
  /** @internal */
  _value: number | bigint
  /** @internal */
  _mutable: boolean

  constructor(descriptor: { value: string; mutable?: boolean }, init?: number | bigint) {
    this._mutable = descriptor.mutable ?? false
    this._value = init ?? 0
  }

  get value(): number | bigint { return this._value }
  set value(v: number | bigint) {
    if (!this._mutable) throw new TypeError('Cannot set value of immutable global')
    this._value = v
  }
}

function buildExports(instHandle: WasmInstanceHandle, exportList: ExportInfo[]): Record<string, Function | WasmMemory | WasmTable | WasmGlobal> {
  const exports: Record<string, Function | WasmMemory | WasmTable | WasmGlobal> = {}

  for (const exp of exportList) {
    if (exp.kind === 'function') {
      exports[exp.name] = (...args: number[]) => {
        const result = Beam.callSync('__wasm_call', instHandle, exp.name, args) as { ok: number; error?: string }
        if (result.error) throw new WasmRuntimeError(result.error)
        return result.ok
      }
    }
  }

  return exports
}

function toUint8Array(source: BufferSource): Uint8Array {
  if (source instanceof Uint8Array) return source
  if (source instanceof ArrayBuffer) return new Uint8Array(source)
  if (ArrayBuffer.isView(source)) return new Uint8Array(source.buffer, source.byteOffset, source.byteLength)
  throw new TypeError('Expected a BufferSource')
}

const WebAssembly = {
  compile(bufferSource: BufferSource): Promise<WasmModule> {
    try {
      return Promise.resolve(new WasmModule(bufferSource))
    } catch (e) {
      return Promise.reject(e)
    }
  },

  instantiate(source: BufferSource | WasmModule, importObject?: ImportObject): Promise<{ module: WasmModule; instance: WasmInstance } | WasmInstance> {
    try {
      if (source instanceof WasmModule) {
        return Promise.resolve(new WasmInstance(source, importObject))
      }
      const module = new WasmModule(source as BufferSource)
      const instance = new WasmInstance(module, importObject)
      return Promise.resolve({ module, instance })
    } catch (e) {
      return Promise.reject(e)
    }
  },

  validate(bufferSource: BufferSource): boolean {
    try {
      const bytes = toUint8Array(bufferSource)
      return Beam.callSync('__wasm_validate', bytes) as boolean
    } catch {
      return false
    }
  },

  Module: WasmModule,
  Instance: WasmInstance,
  Memory: WasmMemory,
  Table: WasmTable,
  Global: WasmGlobal,
  CompileError: WasmCompileError,
  LinkError: WasmLinkError,
  RuntimeError: WasmRuntimeError,
}

Object.assign(globalThis, { WebAssembly })
