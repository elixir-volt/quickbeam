# Autoresearch: Web API Builtins for BEAM Mode

## Objective
Implement ALL web APIs as native BEAM builtins so the full web_apis_test suite passes in beam mode. The test file `test/web_apis/beam_web_apis_test.exs` is a copy of `test/web_apis/web_apis_test.exs` running in `mode: :beam`.

## Metrics
- **Primary**: `failing_tests` (count, lower is better) — number of beam web API test failures
- **Secondary**: `passing_tests`

## How to Run
`./autoresearch.sh`

## Architecture
Web API builtins are registered in `lib/quickbeam/vm/runtime/web/` modules and aggregated via `lib/quickbeam/vm/runtime/web_apis.ex`. Each module uses the `build_object`/`build_methods`/`method`/`val` macros from `QuickBEAM.VM.Builtin`. Constructor registration uses `WebAPIs.register/2`.

Existing Elixir implementations should be called directly where they exist (e.g., `QuickBEAM.URL` for URL parsing, `:crypto` for random, `Base` for base64).

For missing global functions like `encodeURIComponent`, `parseInt`, `parseFloat` — these are ECMAScript builtins that should be added to `lib/quickbeam/vm/runtime/globals.ex`.

## Constraints
- `mix test test/vm/beam_compat_test.exs test/vm/compiler_test.exs` must pass
- Use existing `QuickBEAM.VM.Builtin` macros (`build_object`, `build_methods`, `method`, `val`)
- Use `WebAPIs.register/2` for constructor registration (no copy-paste)
- New web API modules go under `lib/quickbeam/vm/runtime/web/`
- No new dependencies
