# Autoresearch: Full Web API Builtins for BEAM Mode

## Objective
Implement all web APIs as native BEAM builtins so every web API test passes in beam mode. Tests are beam-mode mirrors of existing NIF test files under `test/web_apis/beam_*_test.exs`.

## Metrics
- **Primary**: `failing_tests` (count, lower is better)
- **Secondary**: `passing_tests`

## How to Run
`./autoresearch.sh`

## Test files
- `beam_web_apis_test.exs` — TextEncoder/Decoder, URL, atob/btoa, crypto, timers, etc. (92 tests)
- `beam_new_web_apis_test.exs` — EventTarget, AbortSignal, Blob, Headers, DOMException (38 tests)
- `beam_url_test.exs` — URL/URLSearchParams edge cases (53 tests)
- `beam_form_data_test.exs` — FormData (44 tests)
- `beam_fetch_test.exs` — fetch/Request/Response (23 tests)
- `beam_performance_test.exs` — performance.now/mark/measure (61 tests)

## Architecture
Web API builtins live in `lib/quickbeam/vm/runtime/web/*.ex`, aggregated by `web_apis.ex`. Use `build_object`/`build_methods` macros, `WebAPIs.register/2` for constructors. Call existing Elixir implementations directly where they exist.

## Constraints
- `mix test test/vm/beam_compat_test.exs test/vm/compiler_test.exs` must pass
- Use existing `QuickBEAM.VM.Builtin` macros
- New modules under `lib/quickbeam/vm/runtime/web/`
