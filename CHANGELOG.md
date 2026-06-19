# Changelog

## Unreleased

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
