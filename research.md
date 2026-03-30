# Research: Wasmtime C API

## Summary

Wasmtime provides a pure C embedding API (`wasmtime.h`) with no C++ dependencies, making it fully Zig-compatible via `@cImport`. The API follows a compile → store → instantiate → call pattern with opaque types and explicit lifecycle management. It ships as a precompiled static/dynamic library (`libwasmtime.a`/`.dylib`/`.so`) built from Rust, linked against pure C headers.

## Findings

### 1. Directory Structure and Header Organization

The C API lives in `crates/c-api/` with this structure:

```
crates/c-api/
├── include/
│   ├── wasm.h              # WebAssembly/wasm-c-api standard (vendored from upstream)
│   ├── wasi.h              # WASI configuration
│   ├── wasmtime.h           # Main entry point — includes all sub-headers
│   ├── wasmtime.hh          # C++ wrapper (header-only, C++17, NOT needed for C)
│   ├── wasm.hh              # C++ wrapper for wasm.h (NOT needed for C)
│   ├── doc-wasm.h           # Documentation overlay
│   └── wasmtime/
│       ├── config.h         # Engine configuration
│       ├── engine.h         # Engine (compilation context)
│       ├── store.h          # Store + Context (runtime state)
│       ├── module.h         # Module compilation/serialization
│       ├── instance.h       # Module instantiation
│       ├── func.h           # Function creation/calling
│       ├── linker.h         # Name-based linker for imports
│       ├── memory.h         # Linear memory access
│       ├── table.h          # Table operations
│       ├── global.h         # Global variables
│       ├── val.h            # Value types (i32, i64, f32, f64, v128, funcref, externref, anyref)
│       ├── extern.h         # External item representation (tagged union)
│       ├── error.h          # Error handling
│       ├── trap.h           # Trap handling
│       ├── conf.h           # Feature flag defines (WASMTIME_FEATURE_*)
│       ├── async.h          # Async support
│       ├── wat.h            # WAT text format parsing
│       ├── profiling.h      # Profiling hooks
│       ├── sharedmemory.h   # Shared memory (threads proposal)
│       ├── tag.h            # Exception handling tags
│       └── component.h      # Component Model support
├── src/                     # Rust implementation of C API bindings
├── tests/                   # C API tests
├── cmake/                   # CMake build configuration
├── CMakeLists.txt           # CMake build file
├── Cargo.toml               # Rust crate manifest
└── build.rs                 # Rust build script
```

Current version: **Wasmtime 44.0.0**. [Source](https://github.com/bytecodealliance/wasmtime/tree/main/crates/c-api)

### 2. Compile / Instantiate / Call Pattern

The core API flow with key types and functions:

```c
// 1. CREATE ENGINE (global, thread-safe, reusable)
wasm_engine_t *engine = wasm_engine_new();

// 2. CREATE STORE (per-request/per-instance isolation unit)
wasmtime_store_t *store = wasmtime_store_new(engine, user_data, finalizer);
wasmtime_context_t *context = wasmtime_store_context(store);

// 3. COMPILE MODULE (thread-safe, cacheable, engine-scoped)
wasmtime_module_t *module = NULL;
wasmtime_error_t *error = wasmtime_module_new(engine, wasm_bytes, wasm_len, &module);

// 4. DEFINE HOST FUNCTIONS
//    Option A: Direct function creation (store-specific)
wasmtime_func_t func;
wasmtime_func_new(context, functype, callback, env, finalizer, &func);

//    Option B: Linker-based (store-independent, preferred)
wasmtime_linker_t *linker = wasmtime_linker_new(engine);
wasmtime_linker_define_func(linker, "mod", 3, "fn", 2, functype, callback, data, NULL);

// 5. INSTANTIATE
wasmtime_instance_t instance;
wasm_trap_t *trap = NULL;

//    Option A: Direct (requires manual import array, 1:1 order)
wasmtime_extern_t imports[] = { {.kind = WASMTIME_EXTERN_FUNC, .of.func = func} };
error = wasmtime_instance_new(context, module, imports, 1, &instance, &trap);

//    Option B: Linker (name-based resolution, preferred)
error = wasmtime_linker_instantiate(linker, context, module, &instance, &trap);

//    Option C: Pre-instantiation (validate once, instantiate many)
wasmtime_instance_pre_t *pre = NULL;
error = wasmtime_linker_instantiate_pre(linker, module, &pre);
error = wasmtime_instance_pre_instantiate(pre, context, &instance, &trap);

// 6. EXTRACT EXPORT
wasmtime_extern_t run_export;
bool found = wasmtime_instance_export_get(context, &instance, "run", 3, &run_export);
// run_export.kind == WASMTIME_EXTERN_FUNC

// 7. CALL FUNCTION
wasmtime_val_t args[1] = { {.kind = WASMTIME_I32, .of.i32 = 42} };
wasmtime_val_t results[1];
error = wasmtime_func_call(context, &run_export.of.func, args, 1, results, 1, &trap);
// Three possible outcomes:
//   error != NULL  → programmer error (wrong types/count)
//   trap != NULL   → wasm trapped during execution
//   both NULL      → success, results are valid

// 8. MEMORY ACCESS
wasmtime_extern_t mem_export;
wasmtime_instance_export_get(context, &instance, "memory", 6, &mem_export);
uint8_t *data = wasmtime_memory_data(context, &mem_export.of.memory);
size_t byte_len = wasmtime_memory_data_size(context, &mem_export.of.memory);

// 9. CLEANUP (reverse order)
wasmtime_module_delete(module);
wasmtime_store_delete(store);
wasm_engine_delete(engine);
```

**Host function callback signature:**
```c
wasm_trap_t *callback(void *env, wasmtime_caller_t *caller,
                      const wasmtime_val_t *args, size_t nargs,
                      wasmtime_val_t *results, size_t nresults);
// Return NULL for success, or a wasm_trap_t* to trap
// Use wasmtime_caller_context(caller) to get store context
// Use wasmtime_caller_export_get(caller, ...) to access instance exports
```

**Unchecked (fast) variants** exist for performance-critical paths:
- `wasmtime_func_new_unchecked()` / `wasmtime_func_call_unchecked()` — skip type validation, use `wasmtime_val_raw_t` union directly. [Source](https://docs.wasmtime.dev/c-api/func_8h.html)

**Key architectural notes:**
- **Engine** is the compilation context — thread-safe, globally shared
- **Store** is the isolation unit — one per "request", not long-lived
- **Module** is compiled bytecode — thread-safe, cacheable across stores
- **Context** is an interior pointer into Store — passed everywhere, NOT owned
- Objects are represented as integer handles (indices), not pointers — `wasmtime_func_t`, `wasmtime_memory_t`, etc. are small value types with a `store_id` + index fields [Source](https://docs.wasmtime.dev/c-api/wasmtime_8h.html)

### 3. Resource Management and Store Lifecycle

```c
// Store-level resource limits
wasmtime_store_limiter(store,
    16 * 1024 * 1024,  // max memory bytes (16MB)
    10000,             // max table elements
    10,                // max instances
    10,                // max tables
    10                 // max memories
);

// Fuel-based execution limits
wasmtime_config_consume_fuel_set(config, true);
wasmtime_context_set_fuel(context, 10000);
uint64_t remaining;
wasmtime_context_get_fuel(context, &remaining);

// Epoch-based interruption
wasmtime_config_epoch_interruption_set(config, true);
wasmtime_context_set_epoch_deadline(context, 1);
wasm_engine_increment_epoch(engine); // call from another thread

// Module serialization (AOT cache)
wasm_byte_vec_t serialized;
wasmtime_module_serialize(module, &serialized);
wasmtime_module_deserialize(engine, serialized.data, serialized.size, &module);
wasmtime_module_deserialize_file(engine, "/path/to/cached.bin", &module);
```

[Source](https://docs.wasmtime.dev/c-api/store_8h.html)

### 4. Zig Compatibility — YES, Fully Compatible

The C API is **pure C99/C11** with zero C++ dependencies:

- **All `.h` headers use `extern "C"` guards** — only activated when `__cplusplus` is defined, which Zig's `@cImport` does NOT define
- **No C++ features anywhere** — no templates, classes, namespaces, exceptions, RTTI
- **Standard C types only** — `stdint.h`, `stddef.h`, `stdbool.h`, `stdalign.h`, `string.h`
- **Function pointer callbacks** use standard C calling conventions
- **Struct layouts** are plain C structs/unions with fixed sizes

**Potential Zig `@cImport` issues to watch for:**

1. **`wasm.h` uses `static_assert`** — the `assertions()` inline function and `__wasmtime_val_assertions()` use C11 `static_assert`. Zig's C frontend handles this.

2. **`wasm.h` uses `inline` functions** — Several convenience helpers like `wasm_functype_new_0_0()`, `wasm_name_new_from_string()` are `static inline`. Zig's translate-c handles these, but complex ones may need manual re-implementation.

3. **`#define own`** — The `own` macro is defined as empty (documentation annotation). This should be harmless to Zig's C parser.

4. **Preprocessor macros for type declarations** — `WASM_DECLARE_VEC`, `WASM_DECLARE_OWN`, `WASM_DECLARE_TYPE` etc. generate types and function declarations via macros. Zig's `@cImport` expands these correctly.

5. **`__alignof` in `val.h`** — Used in `static_assert` within `__wasmtime_val_assertions()`. This is a GCC/Clang extension. Should be fine since it's inside a never-called assertion function.

6. **`WASM_API_EXTERN` on Windows** — Defaults to `__declspec(dllimport)` on `_WIN32`. For static linking, define `-DWASM_API_EXTERN=` and `-DWASI_API_EXTERN=`. On macOS/Linux, it's empty by default.

7. **Feature flags** — Headers use `#ifdef WASMTIME_FEATURE_WASI` and `#ifdef WASMTIME_FEATURE_COMPILER`. The `wasmtime/conf.h` generated file controls these. Prebuilt releases include all features enabled.

**Existing Zig bindings confirm compatibility:** The [zigwasm/wasmtime-zig](https://github.com/zigwasm/wasmtime-zig) project (86 stars) successfully wraps the C API from Zig, using `@cImport` to import `wasm.h` and `wasmtime.h`, then providing an idiomatic Zig wrapper. Last updated for Wasmtime v0.24.0 (old), but proves the approach works. [Source](https://github.com/zigwasm/wasmtime-zig)

**Linking from Zig:**
```zig
// In build.zig:
exe.addIncludePath(.{ .path = "wasmtime/include" });
exe.addLibraryPath(.{ .path = "wasmtime/lib" });
exe.linkSystemLibrary("wasmtime");
// On Linux, also link: pthread, dl, m

// In Zig code:
const c = @cImport({
    @cInclude("wasmtime.h");
});
```

### 5. Error Handling Pattern

The API uses a consistent three-way return pattern:

```c
wasmtime_error_t *error = wasmtime_func_call(context, &func, args, nargs, results, nresults, &trap);

if (error != NULL) {
    // Programmer error (wrong arg count, type mismatch, cross-store access)
    wasm_byte_vec_t msg;
    wasmtime_error_message(error, &msg);
    // use msg.data (msg.size bytes)
    wasm_byte_vec_delete(&msg);
    wasmtime_error_delete(error);
} else if (trap != NULL) {
    // Wasm execution trapped (stack overflow, unreachable, OOB memory, etc.)
    wasm_byte_vec_t msg;
    wasm_trap_message(trap, &msg);
    // msg includes stack trace
    wasm_byte_vec_delete(&msg);
    wasm_trap_delete(trap);
} else {
    // Success — results are valid
}
```

### 6. WASI Support

```c
// Configure linker with WASI imports
wasmtime_linker_define_wasi(linker);

// Configure store with WASI state
wasi_config_t *wasi_config = wasi_config_new();
wasi_config_inherit_argv(wasi_config);
wasi_config_inherit_env(wasi_config);
wasi_config_inherit_stdin(wasi_config);
wasi_config_inherit_stdout(wasi_config);
wasi_config_inherit_stderr(wasi_config);
wasmtime_context_set_wasi(context, wasi_config); // takes ownership of wasi_config
```

### 7. Thread Safety Model

- `wasm_engine_t` — thread-safe, share globally
- `wasmtime_module_t` — thread-safe, share across threads
- `wasmtime_store_t` / `wasmtime_context_t` — NOT thread-safe, use per-thread or with external synchronization
- `const wasmtime_context_t*` parameters — safe for concurrent reads
- `wasmtime_context_t*` parameters — require exclusive access [Source](https://docs.wasmtime.dev/c-api/wasmtime_8h.html)

### 8. Building the C API Library

```sh
# From Rust source (produces target/release/libwasmtime.{a,dylib,so,dll})
cargo build --release -p wasmtime-c-api

# Via CMake (recommended for installation)
cmake -S crates/c-api -B target/c-api --install-prefix "$(pwd)/artifacts"
cmake --build target/c-api
cmake --install target/c-api
# Produces: artifacts/lib/libwasmtime.{a,dylib} + artifacts/include/**/*.h

# Or download prebuilt from GitHub Releases (artifacts ending in "-c-api")
# e.g. wasmtime-v44.0.0-aarch64-macos-c-api.tar.xz
```

[Source](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/README.md)

## Sources

- **Kept:** [Wasmtime C API docs](https://docs.wasmtime.dev/c-api/) — Official Doxygen-generated API reference
- **Kept:** [wasmtime.h source](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime.h) — Main header, includes architectural overview
- **Kept:** [hello.c example](https://github.com/bytecodealliance/wasmtime/blob/main/examples/hello.c) — Complete working example of compile→instantiate→call
- **Kept:** [func.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/func.h) — Host function creation and calling
- **Kept:** [store.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/store.h) — Store/context lifecycle, fuel, epochs
- **Kept:** [linker.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/linker.h) — Name-based linking and WASI
- **Kept:** [module.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/module.h) — Compilation, serialization, deserialization
- **Kept:** [memory.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/memory.h) — Linear memory access
- **Kept:** [val.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/val.h) — Value types including anyref/externref/v128
- **Kept:** [extern.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasmtime/extern.h) — External item representation
- **Kept:** [wasm.h](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/include/wasm.h) — Standard wasm-c-api types
- **Kept:** [zigwasm/wasmtime-zig](https://github.com/zigwasm/wasmtime-zig) — Proof that Zig `@cImport` works with wasmtime headers
- **Kept:** [c-api README](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/README.md) — Build instructions and Rust integration
- **Kept:** [Issue #3979](https://github.com/bytecodealliance/wasmtime/issues/3979) — Static linking on Windows requires `-DWASM_API_EXTERN=`
- **Dropped:** [Issue #1911](https://github.com/bytecodealliance/wasmtime/issues/1911) — Old discussion about host context in callbacks (2020), addressed by current API design
- **Dropped:** [wasmtime-cpp](https://github.com/bytecodealliance/wasmtime-cpp) — C++ wrapper, archived April 2025, irrelevant for Zig
- **Dropped:** [Issue #2253](https://github.com/bytecodealliance/wasmtime/issues/2253) — Old `(void)` prototype issue in wasm.h, fixed in 2021

## Gaps

1. **No official Zig build.zig integration** — The zigwasm/wasmtime-zig project is stale (Zig 0.8, Wasmtime 0.24). A modern integration would need updating for Zig 0.15+ and Wasmtime 44+.

2. **Component Model C API** — `wasmtime/component.h` exists but wasn't examined in depth. The Component Model is newer and may have a less stable C API surface.

3. **Async C API** — `wasmtime/async.h` exists for async function calls but wasn't examined. Relevant if you need non-blocking wasm execution.

4. **Cross-compilation details** — Prebuilt releases cover linux-x86_64, macos-aarch64, windows-x86_64, but the full matrix and Zig cross-compilation story (linking a Rust-built static lib from Zig targeting a different platform) hasn't been verified.
