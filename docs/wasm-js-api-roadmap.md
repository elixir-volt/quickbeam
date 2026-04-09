# WebAssembly JS API roadmap

## Goal

Bring QuickBEAM's `WebAssembly` polyfill closer to the WebAssembly JavaScript Interface standard.

## Standards checked

- https://webassembly.github.io/spec/js-api/
- https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface
- https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/instantiate_static
- https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Module
- https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Memory
- https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Table
- https://developer.mozilla.org/en-US/docs/WebAssembly/Reference/JavaScript_interface/Global

## Current status

### Implemented

- `WebAssembly.compile(bytes)`
- `WebAssembly.instantiate(bytes | module)`
- `WebAssembly.validate(bytes)`
- `new WebAssembly.Module(bytes)`
- `new WebAssembly.Instance(module)`
- `WebAssembly.Module.exports(module)`
- `WebAssembly.Module.imports(module)`
- numeric wasm calls for `i32`, `i64`, `f32`, `f64`
- `i64` results mapped to JS `BigInt`
- exported numeric globals
- exported memory exposure
- `WebAssembly.Module.customSections()`
- `WebAssembly.compileStreaming()`
- `WebAssembly.instantiateStreaming()`
- `importObject` validation for function/memory/global imports
- JS-owned function imports executed inline on the owning QuickJS worker / ContextPool thread
- snapshot-style memory/global imports for instantiation
- exported imported memory reuses the original `WebAssembly.Memory` wrapper

### Not yet standard-complete

- runtime-backed `Memory.buffer` semantics
- runtime-backed tables
- full global import/export parity
- table imports
- live shared imported memory/global semantics
- compile options (`builtins`, `importedStringConstants`)
- `Tag`, `Exception`, `JSTag`
- exact object caching / identity semantics from the spec
- exact error semantics for every edge case

## Implementation phases

### Phase 1 — Instantiation and linking

1. harden function imports around shared budget / instruction limits
2. implement memory imports
3. implement table imports
4. implement global imports
5. validate `importObject` shape and types
6. return `LinkError` and `TypeError` in the right places

### Phase 2 — Memory

1. make exported memory runtime-backed
2. make imported memory visible to wasm
3. improve `buffer` semantics
4. improve `grow()` semantics

### Phase 3 — Table

1. make exported tables runtime-backed
2. make imported tables runtime-backed
3. implement shared JS/wasm mutation visibility

### Phase 4 — Global

1. imported globals
2. exported globals with shared state
3. mutability checks
4. `i64` globals as `BigInt`

### Phase 5 — Namespace completeness

1. `compileStreaming()`
2. `instantiateStreaming()`
3. `Module.customSections()`

### Phase 6 — JS API 2.0 / newer features

1. compile options
2. `WebAssembly.JSTag`
3. `WebAssembly.Tag`
4. `WebAssembly.Exception`

## Recommended order

1. imports
2. real memory semantics
3. real tables
4. real globals
5. streaming and custom sections
6. newer API additions
