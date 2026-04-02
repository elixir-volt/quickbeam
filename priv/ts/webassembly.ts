class WasmCompileError extends Error {
  constructor(message?: string) {
    super(message)
    this.name = 'CompileError'
  }
}

class WasmLinkError extends Error {
  constructor(message?: string) {
    super(message)
    this.name = 'LinkError'
  }
}

class WasmRuntimeError extends Error {
  constructor(message?: string) {
    super(message)
    this.name = 'RuntimeError'
  }
}

type WasmModuleHandle = number
type WasmInstanceHandle = number
type ValueType = string

interface ImportObject {
  [module: string]: { [name: string]: Function | WasmMemory | WasmTable | WasmGlobal }
}

interface ExportInfo {
  name: string
  kind: string
  index?: number
  params?: ValueType[]
  results?: ValueType[]
  type?: ValueType
  mutable?: boolean
  element?: string
  min?: number
  max?: number | null
}

interface ImportInfo extends ExportInfo {
  module: string
}

class WasmModule {
  _handle: WasmModuleHandle

  constructor(bufferSource: BufferSource) {
    const bytes = wasmToUint8Array(bufferSource)
    const result = Beam.callSync('__wasm_compile', bytes) as {
      ok: WasmModuleHandle
      error?: string
    }
    if (result.error) throw new WebAssembly.CompileError(result.error)
    this._handle = result.ok
  }

  static exports(module: WasmModule): ExportInfo[] {
    return Beam.callSync('__wasm_module_exports', module._handle) as ExportInfo[]
  }

  static imports(module: WasmModule): ImportInfo[] {
    return Beam.callSync('__wasm_module_imports', module._handle) as ImportInfo[]
  }

  static customSections(module: WasmModule, sectionName: string): ArrayBuffer[] {
    const sections = Beam.callSync(
      '__wasm_module_custom_sections',
      module._handle,
      sectionName
    ) as BufferSource[]
    return sections.map((section) => wasmToUint8Array(section).slice().buffer)
  }
}

interface PreparedImports {
  payload: Record<string, unknown>[]
  boundMemories: Array<{ index: number; memory: WasmMemory }>
  boundGlobals: Array<{ index: number; global: WasmGlobal }>
}

class WasmInstance {
  exports: Record<string, Function | WasmMemory | WasmTable | WasmGlobal>
  _handle: WasmInstanceHandle

  constructor(module: WasmModule, importObject?: ImportObject) {
    const imports = WasmModule.imports(module)
    const prepared = prepareImports(imports, importObject)

    const result = Beam.callSync('__wasm_start', module._handle, prepared.payload) as {
      ok: WasmInstanceHandle
      error?: string
    }
    if (result.error) throw new WebAssembly.LinkError(result.error)
    this._handle = result.ok

    for (const binding of prepared.boundMemories) {
      if (binding.memory._handle === null) {
        binding.memory._buffer = null
        binding.memory._handle = this._handle
      }
    }

    this.exports = buildExports(this._handle, WasmModule.exports(module), prepared)
  }
}

class WasmMemory {
  _buffer: ArrayBuffer | null = null
  _handle: WasmInstanceHandle | null
  _initial: number
  _maximum?: number
  _shared: boolean

  constructor(
    descriptor: { initial: number; maximum?: number; shared?: boolean },
    handle?: WasmInstanceHandle
  ) {
    this._handle = handle ?? null
    this._initial = descriptor.initial
    this._maximum = descriptor.maximum
    this._shared = descriptor.shared ?? false
    if (this._handle === null) this._buffer = new ArrayBuffer(descriptor.initial * 65536)
  }

  get buffer(): ArrayBuffer {
    if (this._handle === null) {
      if (this._buffer === null) throw new WebAssembly.RuntimeError('memory not initialized')
      return this._buffer
    }

    const size = wasmCall('__wasm_memory_size', this._handle) as number
    const bytes = wasmCall('__wasm_read_memory', this._handle, 0, size) as BufferSource
    return wasmToUint8Array(bytes).slice().buffer
  }

  grow(delta: number): number {
    if (this._handle === null) {
      if (this._buffer === null) throw new WebAssembly.RuntimeError('memory not initialized')
      const oldPages = this._buffer.byteLength / 65536
      const newBuffer = new ArrayBuffer((oldPages + delta) * 65536)
      new Uint8Array(newBuffer).set(new Uint8Array(this._buffer))
      this._buffer = newBuffer
      return oldPages
    }

    return wasmCall('__wasm_memory_grow', this._handle, delta) as number
  }
}

class WasmTable {
  _entries: (Function | null)[]
  length: number

  constructor(descriptor: { element: string; initial: number; maximum?: number }) {
    this._entries = Array.from({ length: descriptor.initial }, () => null)
    this.length = descriptor.initial
  }

  get(index: number): Function | null {
    return this._entries[index] ?? null
  }

  set(index: number, value: Function | null): void {
    this._entries[index] = value
  }

  grow(delta: number): number {
    const old = this._entries.length
    for (let i = 0; i < delta; i++) this._entries.push(null)
    this.length = this._entries.length
    return old
  }
}

class WasmGlobal {
  _value: number | bigint
  _mutable: boolean
  _type: ValueType
  _handle: WasmInstanceHandle | null
  _name: string | null

  constructor(
    descriptor: { value: ValueType; mutable?: boolean },
    init?: number | bigint,
    handle?: WasmInstanceHandle,
    name?: string
  ) {
    this._mutable = descriptor.mutable ?? false
    this._type = descriptor.value
    this._value = init ?? 0
    this._handle = handle ?? null
    this._name = name ?? null
  }

  get value(): number | bigint {
    if (this._handle === null || this._name === null) return this._value
    return decodeNumericScalar(wasmCall('__wasm_read_global', this._handle, this._name), this._type)
  }

  set value(v: number | bigint) {
    if (!this._mutable) throw new TypeError('Cannot set value of immutable global')

    if (this._handle === null || this._name === null) {
      this._value = v
      return
    }

    const encoded = encodeScalar(v, this._type)
    this._value = decodeNumericScalar(
      wasmCall('__wasm_write_global', this._handle, this._name, encoded),
      this._type
    )
  }
}

function prepareImports(imports: ImportInfo[], importObject?: ImportObject): PreparedImports {
  if (imports.length === 0) return { payload: [], boundMemories: [], boundGlobals: [] }
  if (!importObject || typeof importObject !== 'object') throw new WebAssembly.LinkError('importObject is required for this module')

  const payload: Record<string, unknown>[] = []
  const boundMemories: Array<{ index: number; memory: WasmMemory }> = []
  const boundGlobals: Array<{ index: number; global: WasmGlobal }> = []
  let memoryIndex = 0
  let globalIndex = 0

  for (const imp of imports) {
    const value = lookupImportValue(importObject, imp)
    if (imp.kind === 'function') throw new WebAssembly.LinkError(`function imports are not supported yet (${imp.module}.${imp.name})`)
    if (imp.kind === 'table') throw new WebAssembly.LinkError(`table imports are not supported yet (${imp.module}.${imp.name})`)

    if (imp.kind === 'memory') {
      const memory = prepareMemoryImport(imp, value)
      payload.push(memory.payload)
      boundMemories.push({ index: memoryIndex, memory: memory.memory })
      memoryIndex += 1
      continue
    }

    if (imp.kind === 'global') {
      const global = prepareGlobalImport(imp, value)
      payload.push(global.payload)
      boundGlobals.push({ index: globalIndex, global: global.global })
      globalIndex += 1
      continue
    }

    throw new WebAssembly.LinkError(`unsupported import kind ${imp.kind}`)
  }

  return { payload, boundMemories, boundGlobals }
}

function lookupImportValue(importObject: ImportObject, imp: ImportInfo) {
  const namespace = importObject[imp.module] as ImportObject[string] | undefined
  if (namespace === undefined) throw new WebAssembly.LinkError(`missing import module ${imp.module}`)

  const value = (namespace as Record<string, Function | WasmMemory | WasmTable | WasmGlobal | undefined>)[imp.name]
  if (value === undefined) throw new WebAssembly.LinkError(`missing import ${imp.module}.${imp.name}`)
  return value
}

function prepareMemoryImport(imp: ImportInfo, value: Function | WasmMemory | WasmTable | WasmGlobal) {
  if (!(value instanceof WasmMemory)) throw new TypeError(`import ${imp.module}.${imp.name} must be a WebAssembly.Memory`)

  const currentPages = value.buffer.byteLength / 65536
  const maximum = value._maximum

  if (currentPages < (imp.min ?? 0)) {
    throw new WebAssembly.LinkError(`memory import ${imp.module}.${imp.name} is too small`)
  }

  if (imp.max !== undefined && imp.max !== null) {
    if (currentPages > imp.max) {
      throw new WebAssembly.LinkError(`memory import ${imp.module}.${imp.name} exceeds maximum`)
    }

    if (maximum === undefined || maximum > imp.max) {
      throw new WebAssembly.LinkError(`memory import ${imp.module}.${imp.name} has incompatible maximum`)
    }
  }

  return {
    memory: value,
    payload: {
      module: imp.module,
      name: imp.name,
      kind: imp.kind,
      min: currentPages,
      max: maximum ?? null,
      bytes: new Uint8Array(value.buffer)
    }
  }
}

function prepareGlobalImport(imp: ImportInfo, value: Function | WasmMemory | WasmTable | WasmGlobal) {
  if (!(value instanceof WasmGlobal)) throw new TypeError(`import ${imp.module}.${imp.name} must be a WebAssembly.Global`)
  if (value._type !== imp.type || value._mutable !== (imp.mutable ?? false)) {
    throw new WebAssembly.LinkError(`global import ${imp.module}.${imp.name} has incompatible type`)
  }

  return {
    global: value,
    payload: {
      module: imp.module,
      name: imp.name,
      kind: imp.kind,
      type: value._type,
      mutable: value._mutable,
      value: encodeScalar(value.value, value._type)
    }
  }
}

function buildExports(
  instHandle: WasmInstanceHandle,
  exportList: ExportInfo[],
  preparedImports?: PreparedImports
): Record<string, Function | WasmMemory | WasmTable | WasmGlobal> {
  const exports: Record<string, Function | WasmMemory | WasmTable | WasmGlobal> = {}

  for (const exp of exportList) {
    if (exp.kind === 'function') {
      exports[exp.name] = (...args: unknown[]) => {
        const encodedArgs = encodeArgs(args, exp.params ?? [])
        const result = wasmCall('__wasm_call', instHandle, exp.name, encodedArgs)
        return decodeResult(result, exp.results ?? [])
      }
      continue
    }

    if (exp.kind === 'memory') {
      const importedMemory = preparedImports?.boundMemories.find((binding) => binding.index === exp.index)
      exports[exp.name] =
        importedMemory?.memory ??
        new WasmMemory({ initial: exp.min ?? 0, maximum: exp.max ?? undefined }, instHandle)
      continue
    }

    if (exp.kind === 'global') {
      const importedGlobal = preparedImports?.boundGlobals.find((binding) => binding.index === exp.index)
      if (importedGlobal) {
        importedGlobal.global._handle = instHandle
        importedGlobal.global._name = exp.name
        exports[exp.name] = importedGlobal.global
        continue
      }

      const global = new WasmGlobal(
        { value: exp.type ?? 'i32', mutable: exp.mutable ?? false },
        0,
        instHandle,
        exp.name
      )
      exports[exp.name] = global
      continue
    }

    if (exp.kind === 'table') {
      exports[exp.name] = new WasmTable({
        element: exp.element ?? 'funcref',
        initial: exp.min ?? 0,
        maximum: exp.max ?? undefined
      })
    }
  }

  return exports
}

function encodeArgs(args: unknown[], params: ValueType[]): unknown[] {
  if (params.length > 0 && args.length !== params.length) {
    throw new TypeError(`Expected ${params.length} arguments, got ${args.length}`)
  }

  if (params.length === 0) return args
  return args.map((arg, index) => encodeScalar(arg, params[index]))
}

function encodeScalar(value: unknown, type: ValueType): unknown {
  switch (type) {
    case 'i32':
      return toInteger(value, 'i32')
    case 'i64':
      return typeof value === 'bigint' ? value : BigInt(toInteger(value, 'i64'))
    case 'f32':
    case 'f64':
      if (typeof value !== 'number') throw new TypeError(`Expected number for ${type}`)
      return value
    default:
      return value
  }
}

function decodeResult(value: unknown, results: ValueType[]): unknown {
  if (results.length === 0) return undefined
  if (results.length === 1) return decodeScalar(value, results[0])

  if (!Array.isArray(value)) {
    return [decodeScalar(value, results[0])]
  }

  return value.map((item, index) => decodeScalar(item, results[index]))
}

function decodeScalar(value: unknown, type: ValueType): unknown {
  if (type === 'i64') return decodeNumericScalar(value, type)
  return value
}

function decodeNumericScalar(value: unknown, type: ValueType): number | bigint {
  if (type === 'i64') {
    if (typeof value === 'bigint') return value
    if (typeof value === 'string') return BigInt(value)
    if (typeof value === 'number' && Number.isSafeInteger(value)) return BigInt(value)
    throw new WebAssembly.RuntimeError('invalid i64 value')
  }

  if (typeof value === 'number') return value
  throw new WebAssembly.RuntimeError(`invalid ${type} value`)
}

function toInteger(value: unknown, type: string): number {
  if (typeof value === 'number' && Number.isInteger(value)) return value
  if (typeof value === 'bigint') return Number(value)
  throw new TypeError(`Expected integer-compatible value for ${type}`)
}

function wasmCall(handler: string, ...args: unknown[]): unknown {
  const result = Beam.callSync(handler, ...args) as { ok: unknown; error?: string }
  if (result.error) throw new WebAssembly.RuntimeError(result.error)
  return result.ok
}

function wasmToUint8Array(source: BufferSource): Uint8Array {
  if (source instanceof Uint8Array) return source
  if (source instanceof ArrayBuffer) return new Uint8Array(source)
  if (ArrayBuffer.isView(source)) {
    return new Uint8Array(source.buffer, source.byteOffset, source.byteLength)
  }
  throw new TypeError('Expected a BufferSource')
}
function toArrayBufferFromResponseLike(response: {
  arrayBuffer(): Promise<ArrayBuffer> | ArrayBuffer
}): Promise<ArrayBuffer> {
  return Promise.resolve(response.arrayBuffer())
}
const quickbeamWebAssembly = {
  compile(bufferSource: BufferSource): Promise<WasmModule> {
    try {
      return Promise.resolve(new WasmModule(bufferSource))
    } catch (e) {
      return Promise.reject(e)
    }
  },

  instantiate(
    source: BufferSource | WasmModule,
    importObject?: ImportObject
  ): Promise<{ module: WasmModule; instance: WasmInstance } | WasmInstance> {
    try {
      if (source instanceof WasmModule) {
        return Promise.resolve(new WasmInstance(source, importObject))
      }

      const module = new WasmModule(source)
      const instance = new WasmInstance(module, importObject)
      return Promise.resolve({ module, instance })
    } catch (e) {
      return Promise.reject(e)
    }
  },

  validate(bufferSource: BufferSource): boolean {
    try {
      const bytes = wasmToUint8Array(bufferSource)
      return Beam.callSync('__wasm_validate', bytes) as boolean
    } catch {
      return false
    }
  },

  compileStreaming(
    source:
      | Promise<{ arrayBuffer(): Promise<ArrayBuffer> | ArrayBuffer }>
      | { arrayBuffer(): Promise<ArrayBuffer> | ArrayBuffer }
  ): Promise<WasmModule> {
    return Promise.resolve(source)
      .then((response) => toArrayBufferFromResponseLike(response))
      .then((bytes) => quickbeamWebAssembly.compile(bytes))
  },

  instantiateStreaming(
    source:
      | Promise<{ arrayBuffer(): Promise<ArrayBuffer> | ArrayBuffer }>
      | { arrayBuffer(): Promise<ArrayBuffer> | ArrayBuffer },
    importObject?: ImportObject
  ): Promise<{ module: WasmModule; instance: WasmInstance }> {
    return Promise.resolve(source)
      .then((response) => toArrayBufferFromResponseLike(response))
      .then((bytes) => quickbeamWebAssembly.instantiate(bytes, importObject)) as Promise<{
      module: WasmModule
      instance: WasmInstance
    }>
  },

  Module: WasmModule,
  Instance: WasmInstance,
  Memory: WasmMemory,
  Table: WasmTable,
  Global: WasmGlobal,
  CompileError: WasmCompileError,
  LinkError: WasmLinkError,
  RuntimeError: WasmRuntimeError
}
Object.assign(globalThis, { WebAssembly: quickbeamWebAssembly })
