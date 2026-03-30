# Research: Wasmtime Platform Support, Build Requirements & Binary Size

## Summary

Wasmtime provides precompiled C API static libraries (`libwasmtime.a`) for all three target platforms (x86_64-linux, aarch64-macos, aarch64-linux) via GitHub Releases. The compressed C API archives are ~10-11 MB each (xz-compressed); the default release `libwasmtime.a` is roughly **62 MB** on disk (uncompressed, with full features). The default `libwasmtime.so` is ~19 MB in release mode but can be stripped down to **~700 KB** with minimal features and aggressive optimization. Building from source requires a **Rust toolchain** and **CMake**.

## Findings

### 1. Platform Support

All three target platforms are fully supported with native Cranelift compiler backends:

| Platform | Tier | Cranelift | Winch | Precompiled C API |
|----------|------|-----------|-------|-------------------|
| `x86_64-unknown-linux-gnu` | **Tier 1** | ✅ | ✅ | ✅ |
| `aarch64-apple-darwin` | **Tier 2** | ✅ | ✅ (as of v35) | ✅ |
| `aarch64-unknown-linux-gnu` | **Tier 2** | ✅ | ✅ (as of v35) | ✅ |

Tier 2 differs from Tier 1 only in lacking continuous fuzzing. All platforms have full Cranelift JIT/AOT support. Additional tier 3 targets include `aarch64-unknown-linux-musl`, iOS, Android, and RISC-V. [Source: Wasmtime Tiers](https://docs.wasmtime.dev/stability-tiers.html)

### 2. Precompiled Static Libraries — Available

Every tagged release includes C API archives with **both** static (`.a`) and dynamic (`.so`/`.dylib`) libraries plus headers. From v43.0.0 (latest as of 2026-03-20):

| Artifact | Compressed Size |
|----------|----------------|
| `wasmtime-v43.0.0-x86_64-linux-c-api.tar.xz` | ~11.0 MB |
| `wasmtime-v43.0.0-aarch64-linux-c-api.tar.xz` | ~11.1 MB |
| `wasmtime-v43.0.0-aarch64-macos-c-api.tar.xz` | ~10.9 MB |

Each archive contains `lib/libwasmtime.a`, `lib/libwasmtime.{so,dylib}`, and `include/` headers. [Source: GitHub Releases API](https://github.com/bytecodealliance/wasmtime/releases/tag/v43.0.0)

There is also a `dev` release channel that is continuously updated from `main`. [Source: Wasmtime Installation Docs](https://docs.wasmtime.dev/cli-install.html)

### 3. Binary Size of `libwasmtime.a`

The **default release build** `libwasmtime.a` is approximately **62 MB** on Windows (per issue #7808 which mentions "wasmtime.lib and it's 62 MB"), and likely similar on other platforms. This is the full-featured static library including Cranelift, WASI, component model, etc.

However, Wasmtime has extensive documentation on minimizing binary size:

| Configuration | `libwasmtime.so` Size (x86_64 Linux) |
|--------------|--------------------------------------|
| Debug build | 260 MB |
| Release build (default features) | **19 MB** |
| Release, `--no-default-features` | **2.1 MB** |
| + `disable-logging` | 2.1 MB |
| + `opt-level=s`, `panic=abort` | 2.0 MB |
| + LTO, `codegen-units=1`, strip | **1.2 MB** |
| + Nightly `-Zbuild-std` | **941 KB** |
| + `-Zbuild-std-features=` | **~700 KB** |

The **minimal dynamic library** (no compiler, Pulley interpreter only) is ~700 KB. A minimal Wasmtime embedding (Wasefire) runs with 256K RAM and ~300K flash. [Source: Wasmtime Minimal Embedding Guide](https://docs.wasmtime.dev/examples-minimal.html)

The Bytecode Alliance reports a minimal Wasmtime C API dynamic library at **698 KiB** and a minimal pre-compiled-module-only runtime at **315 KiB** on x86_64. [Source: Wasmtime Portability Article](https://bytecodealliance.org/articles/wasmtime-portability)

### 4. Build Requirements

**From source (C API):**
- **Rust toolchain** (stable; nightly for minimal builds)
- **CMake** (for the C API build system)
- **C compiler** (for linking)

Build commands:
```sh
# CMake method (recommended for C/C++ projects)
cmake -S crates/c-api -B target/c-api --install-prefix "$(pwd)/artifacts"
cmake --build target/c-api
cmake --install target/c-api

# Cargo method (direct)
cargo build --release -p wasmtime-c-api
```

**Linking dependencies:**
- Linux: `-lpthread -ldl -lm`
- macOS: no extra flags needed
- Windows: `ws2_32.lib advapi32.lib userenv.lib ntdll.lib shell32.lib ole32.lib bcrypt.lib`

For static linking on macOS/Linux, define `-DWASM_API_EXTERN=` and `-DWASI_API_EXTERN=` to avoid dllimport issues. [Source: Wasmtime C API Docs](https://docs.wasmtime.dev/c-api/)

### 5. Feature Selection for Smaller Builds

Key Cargo features that can be disabled:
- `cranelift` / `winch` — removes compilers (use precompiled `.cwasm` modules only)
- `component-model` — removes component model support
- `gc` — removes garbage collection
- `threads` — removes threading support
- The `runtime` + `pulley` features provide a minimal interpreter-based runtime

### 6. Versioning

Latest release: **v43.0.0** (2026-03-20). Wasmtime releases approximately monthly with a new major version each time. Current C API version macro: `WASMTIME_VERSION "43.0.0"`. [Source: wasmtime.h](https://docs.wasmtime.dev/c-api/wasmtime_8h_source.html)

## Sources

- **Kept:**
  - [Wasmtime Platform Support](https://docs.wasmtime.dev/stability-platform-support.html) — official platform docs
  - [Wasmtime Tiers of Support](https://docs.wasmtime.dev/stability-tiers.html) — tier classification matrix
  - [Wasmtime C/C++ API](https://docs.wasmtime.dev/c-api/) — build/link instructions
  - [C API README](https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/README.md) — build from source instructions
  - [GitHub Releases v43.0.0](https://github.com/bytecodealliance/wasmtime/releases/tag/v43.0.0) — actual artifact sizes
  - [Building a Minimal Embedding](https://docs.wasmtime.dev/examples-minimal.html) — binary size optimization guide
  - [Wasmtime Portability Article](https://bytecodealliance.org/articles/wasmtime-portability) — minimal build sizes
  - [Issue #7808](https://github.com/bytecodealliance/wasmtime/issues/7808) — static linking on MSVC, confirms ~62 MB .lib size
  - [PR #9885](https://github.com/bytecodealliance/wasmtime/pull/9885) — aarch64-musl release artifacts added
- **Dropped:**
  - OPA issue #3545 — about Go module vendoring, not directly relevant
  - Warp blog post — about wasm binary size for web apps, not wasmtime library size
  - Stack Overflow C++ wasm question — about wasm output binaries, not wasmtime itself

## Gaps

- **Exact uncompressed `libwasmtime.a` sizes per platform** — the archives are xz-compressed; I have compressed sizes (~10-11 MB) but not exact uncompressed `.a` file sizes for each platform. The 62 MB figure is from a Windows issue. To get precise numbers, download and extract the archives.
- **musl static library availability** — The musl release binaries are dynamically linked against musl (not fully static). For fully static Linux binaries, building from source with musl target is required.
- **Minimum Rust version** — The docs don't specify an MSRV explicitly; it's implied to be recent stable.
