# Changelog

## Unreleased

- Add explicit bounded immutable program pinning with lightweight `QuickBEAM.VM.PinnedProgram` handles, eight fixed persistent slots, binary identities, single-flight admission, owner-monitored leases, deferred unpinning, restart restoration, 32 MiB per-program and 128 MiB total decoded-term admission bounds, and copied-program semantics for ordinary programs. Pinned Vue SSR improves from a 49.21 ms median and 77.15 MiB endpoint process memory to 11.01 ms and 673.3 KiB while preserving exact steps, logical allocation, limits, cancellation, concurrency, and scheduler gates.
- Define the optional BEAM compiler contract with binary artifact identities, a fixed 32-module atom pool, lease/purge/cache lifecycle, versioned runtime ABI boundaries, and validated owner-local before-instruction deoptimization states. Add its supervised module pool, minimal canonical runtime ABI, structured generated-module backend, bounded v26 CFG analysis, specialized fixed-name `:pure_v1` forms, selective bounded nested-function re-entry, guarded opt-in `:scalar_v1` loop/property/global lowering, explicit call actions, exact shared program artifact namespaces, warm artifact/negative-decision caches, and release-quarantined `engine: :compiler` orchestration with native, Preact/Vue/Svelte SSR, selected Test262, resource, concurrency, measurement, and single-scheduler acceptance coverage.
- Remove integer-index keys from redundant object insertion-order lists, bulk-build literal arrays in one heap update, and encode default data descriptors compactly in the existing property map. Exact logical accounting is preserved; paired retained fixtures reduce array endpoint process memory by about 62% and ordinary-object retained VM heap size by 31%.
- Measure and reject a bounded owner-local hidden-class prototype. Although ideal repeated-shape objects retained 13.4% less VM heap, only 82 of 1,130 final Vue objects were wholly eligible; Vue regressed from 47.07 ms to 50.30 ms with higher reductions and no endpoint memory improvement.
- Measure and reject decode-time object-literal allocation plans with reserved identities, exact accounting, fixed tuple builders, and one-shot compact-map materialization. An ideal repeated four-field fixture improved by 10.1%, but only 16 Vue literals per render were eligible and the controlled Vue median regressed by 7.1%.
- Attribute pinned Vue interpreter churn by exact caller: 55.8% of `maps:put/3` calls update the outer object heap, 30.9% update property dictionaries, and 13.0% update globals or closure cells. Reject tuple/OTP-array constant pools, closure-allocation specialization, bulk function/prototype construction, and smaller opcode/property fast paths because lower call counts or reductions did not produce stable endpoint latency without resource regressions; removing 22.6% of traced map writes regressed the single-scheduler Vue median by 7.3%.
- Add bounded static and dynamic compiler-region probes plus a quarantined `compiler_regions: true` executor experiment with binary admission identities, a fixed 256-entry maximum, three-encounter admission, 32-operation straight-line regions, safe early-boundary tuple updates, exact resource accounting, and reproducible SSR measurements. The experiment remains disabled after Vue reached only 0.7% generated coverage and regressed to a 112.70 ms median.
- Cache validated immutable builtin host templates by profile and registry generation, preserving owner-local mutation isolation and exact logical-memory charging while removing repeated installation from warm evaluations.
- Add `QuickBEAM.VM.measure/2` with deterministic step/logical-memory counters, fixed owner-local OTP compiler counters, and endpoint process observations, plus reproducible pinned SSR concurrency, timeout, cancellation, reclamation, and single-scheduler reports.
- Serialize native addon initialization, reuse cached exports for aliases in one runtime, and reject implicit cross-runtime or post-reset reinitialization with a typed error. Add `allow_reinitialization: true` as an explicit compatibility escape hatch for addons that support multiple environments.

## 0.10.19

- Update QuickJS-NG to 0.15.1.
- Make the JS `WebAssembly.instantiate` WASM operand stack and auxiliary heap configurable with `:wasm_stack_size` / `:wasm_heap_size`.
- Enable WASM bulk-memory `memory.copy`/`memory.fill` opcodes (`WASM_ENABLE_BULK_MEMORY_OPT`), so modules from standard toolchains (Go `GOOS=js GOARCH=wasm`, TinyGo, Rust `wasm-bindgen`) that emit them no longer fail to instantiate with `unsupported opcode fc 0a`.
- Update dependencies, including `npm_ex` to 0.7.5 and `oxc_ex` to 0.17.2.

## 0.10.18

- Update `oxc` to 0.17.1.

## 0.10.17

- Update `oxc` to 0.17.0 and use the selector API for import discovery.

## 0.10.16

- Update `oxc` to 0.16.0

## 0.10.15

- Update `oxc` to 0.15.0

## 0.10.14

- Update optional `npm_ex` dependency to 0.7.4

## 0.10.13

- Bump OXC to 0.13 (adds `module_types` bundler option)

## 0.10.12

- Fix `fs.readFileSync` without encoding to return `Buffer` instead of raw `Uint8Array`, so `.toString()` decodes as UTF-8
- Load `Buffer` polyfill in `:node` runtimes (was only available in `:browser` runtimes)
- Work around `enif_make_map_from_arrays` segfault on ERTS 15.0–15.2.2 (OTP 27.0–27.2) when returning JS objects with >128 keys

## 0.10.11

- Hide vendored C symbols in the native library to avoid collisions with other NIFs
- Update optional `npm_ex` dependency to 0.7.1

## 0.10.10

- Update `npm_ex` to 0.7 and make it optional for consumers
- Update `oxc` to 0.12.1
- Update npm toolchain packages with supply-chain policy checks
- Fix lint/static-analysis issues and quiet Bandit test timestamp warnings

## 0.10.8

- Fix precompiled NIF workflow for Linux ARM target

## 0.10.7

- Add Linux ARM precompiled NIF target

## 0.10.6

- Update OXC dependency to 0.11

## 0.10.5

- Update npm dependency to 0.6 and use the `NPM.Resolution.PackageResolver` namespace

## 0.10.4

- Fix segfault on nested empty BEAM map property enumeration (e.g. `Object.keys` on `%{x: %{}}` passed as a var)
- Update QuickJS-NG to latest upstream (fixes GC crash)
- Fix coverage use-after-free

## 0.10.3

- Widen OXC dep to >= 0.7.0 (supports OXC 0.10 with codegen, bind, splice, and bundle :external option)

## 0.10.2

- Allow oxc ~> 0.9 (adds OXC.Format support)

## 0.10.1

- Allow oxc ~> 0.8 (adds OXC.Lint support)

## 0.10.0

### Added

- **JS line coverage** — `QuickBEAM.Cover` integrates with `mix test --cover` to report line-level coverage for all JS/TS code executed through QuickBEAM runtimes. Patches QuickJS to track execution via a per-function hit bitmap with near-zero overhead when disabled. Outputs LCOV and Istanbul JSON. Also works as a sidecar for excoveralls users.
- **`Beam.XML.parse`** — parse XML from JS using OTP's built-in `:xmerl`. Returns JS-friendly objects with `@attr` attributes, `#text` mixed content, and arrays for repeated siblings. Handles namespaces and CDATA.

### Changed

- **Toolchain upgraded to `oxc` 0.7 and `npm` 0.5.3** — bundler rewritten to use `OXC.rewrite_specifiers/3` and `NPM.PackageResolver`, removing ~150 lines of duplicated resolution logic.
- **Default `max_stack_size` increased from 4 MB to 8 MB** — QuickJS's interpreter uses ~150 KB of C stack per JS call frame, limiting recursion to ~27 frames with the old default. The new default supports ~55 frames, covering all typical real-world patterns.

## 0.9.0
