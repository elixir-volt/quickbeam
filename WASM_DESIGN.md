# WASM Support Design

## Overview

WebAssembly support for QuickBEAM via WAMR (WebAssembly Micro Runtime) interpreter mode.

Two layers:
1. **Elixir API** (`QuickBEAM.WASM`) — standalone WASM execution from Elixir
2. **JS API** (`WebAssembly` global) — spec-compliant JS interface inside QuickBEAM runtimes

Plus a pure Elixir WASM binary parser/disassembler (`QuickBEAM.WASM.disasm/1`).

## Runtime: WAMR interpreter mode

- ~57KB code footprint
- Pure C, compiled alongside quickjs.c in our Zig build
- Standard wasm-c-api: engine → store → module → instance → call
- Broad spec coverage: SIMD, EH, tail calls, GC, memory64
- Active maintenance by Bytecode Alliance

## Elixir API — `QuickBEAM.WASM`

```elixir
# Compile
{:ok, module} = QuickBEAM.WASM.compile(wasm_bytes)
{:ok, module} = QuickBEAM.WASM.compile_wat(wat_string)
true = QuickBEAM.WASM.validate(wasm_bytes)
QuickBEAM.WASM.exports(module)
QuickBEAM.WASM.imports(module)

# Start / call / stop
{:ok, instance} = QuickBEAM.WASM.start(module)
{:ok, instance} = QuickBEAM.WASM.start(module,
  imports: %{
    "env" => %{
      "log" => {:fn, [:i32], [], fn [ptr] -> IO.puts("wasm: #{ptr}") end}
    }
  }
)
{:ok, 42} = QuickBEAM.WASM.call(instance, "add", [40, 2])
QuickBEAM.WASM.stop(instance)

# Memory
{:ok, <<...>>} = QuickBEAM.WASM.read_memory(instance, 0, 5)
:ok = QuickBEAM.WASM.write_memory(instance, 0, "hello")
{:ok, 1} = QuickBEAM.WASM.memory_size(instance)
{:ok, 1} = QuickBEAM.WASM.memory_grow(instance, 1)

# Globals
{:ok, 42} = QuickBEAM.WASM.get_global(instance, "counter")
:ok = QuickBEAM.WASM.set_global(instance, "counter", 100)

# Supervised
{:ok, pid} = QuickBEAM.WASM.start_link(
  module: File.read!("priv/wasm/plugin.wasm"),
  imports: %{...},
  name: :wasm_plugin
)

# In supervision tree
children = [
  {QuickBEAM.WASM, name: :renderer, module: wasm_bytes},
]

# Compile once, start many
{:ok, compiled} = QuickBEAM.WASM.compile(wasm_bytes)
children = for i <- 1..4 do
  {QuickBEAM.WASM, name: :"worker_#{i}", module: compiled}
end
```

## Disassembler — `QuickBEAM.WASM.disasm/1`

Pure Elixir parser. No runtime needed. Same `{offset, name, ...operands}` tuple
convention as `QuickBEAM.Bytecode`.

```elixir
{:ok, mod} = QuickBEAM.WASM.disasm(wasm_bytes)

# %QuickBEAM.WASM.Module{
#   version: 1,
#   types: [%{params: [:i32, :i32], results: [:i32]}],
#   imports: [%{module: "env", name: "log", kind: :func, type_idx: 1}],
#   exports: [%{name: "add", kind: :func, index: 0}],
#   functions: [
#     %QuickBEAM.WASM.Function{
#       index: 0, name: "add", type_idx: 0,
#       params: [:i32, :i32], results: [:i32], locals: [],
#       opcodes: [
#         {0, :local_get, 0},
#         {2, :local_get, 1},
#         {4, :i32_add},
#         {5, :end}
#       ]
#     }
#   ],
#   memories: [%{min: 1, max: nil}],
#   tables: [],
#   globals: [],
#   data: [],
#   start: nil,
#   custom_sections: []
# }
```

## JS API — `WebAssembly` global

Spec-compliant per https://webassembly.github.io/spec/js-api/

Static methods:
- `WebAssembly.validate(bufferSource)` → boolean
- `WebAssembly.compile(bufferSource)` → Promise<Module>
- `WebAssembly.instantiate(bufferSource, importObject?)` → Promise<{module, instance}>
- `WebAssembly.instantiate(module, importObject?)` → Promise<Instance>

Constructors:
- `new WebAssembly.Module(bufferSource)`
- `new WebAssembly.Instance(module, importObject?)`
- `new WebAssembly.Memory({initial, maximum?, shared?})`
- `new WebAssembly.Table({element, initial, maximum?})`
- `new WebAssembly.Global({value, mutable?}, init)`

Module introspection:
- `WebAssembly.Module.exports(module)` → [{name, kind}]
- `WebAssembly.Module.imports(module)` → [{module, name, kind}]
- `WebAssembly.Module.customSections(module, name)` → [ArrayBuffer]

Error types:
- `WebAssembly.CompileError`
- `WebAssembly.LinkError`
- `WebAssembly.RuntimeError`

Deferred (P2): `compileStreaming`, `instantiateStreaming`, WASI, Tag/Exception.

## Implementation plan

### Phase 1: Pure Elixir disassembler
- `QuickBEAM.WASM.Module` struct
- `QuickBEAM.WASM.Function` struct
- `QuickBEAM.WASM.Parser` — LEB128, sections, opcodes
- `QuickBEAM.WASM.disasm/1`
- `QuickBEAM.WASM.validate/1` (structural validation)
- `QuickBEAM.WASM.exports/1`, `QuickBEAM.WASM.imports/1`

### Phase 2: WAMR integration (NIF)
- Vendor WAMR C source into priv/c_src/wamr/
- Add to Zig build in native.ex
- NIF functions: wasm_compile, wasm_start, wasm_call, wasm_stop
- NIF resources: WASMModuleResource, WASMInstanceResource
- Elixir GenServer wrapper (`QuickBEAM.WASM`)

### Phase 3: JS WebAssembly global
- Wire WAMR into QuickJS via JS class bindings
- Register WebAssembly namespace, Module, Instance, Memory, Table, Global
- Error types

### Phase 4: Supervised instances
- `QuickBEAM.WASM.start_link/1`
- `child_spec/1`
- Supervision tree support
