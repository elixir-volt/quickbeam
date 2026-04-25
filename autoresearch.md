# Autoresearch: Web API Builtins for BEAM Mode

## Objective
Implement web API builtins natively in the BEAM VM so they work without NIF polyfills. Each API should be registered as a builtin in `lib/quickbeam/vm/runtime/globals.ex` or a dedicated runtime module.

## Metrics
- **Primary**: `failing_tests` (count, lower is better) — number of beam_web_apis_test failures
- **Secondary**: `passing_tests`

## How to Run
`./autoresearch.sh` — runs the beam web API tests and parses failures.

## Architecture

The BEAM VM has a `Runtime.Globals` module that registers builtins available to JS code. Web APIs should be added there as `{:builtin, name, callback}` entries or as object maps with methods.

Example for TextEncoder:
```elixir
# In Runtime.Globals or a new Runtime.WebAPIs module
"TextEncoder" => register("TextEncoder", fn _args, _this ->
  Heap.wrap(%{
    "encoding" => "utf-8",
    "encode" => {:builtin, "encode", fn [str | _], _this ->
      bytes = :binary.bin_to_list(str)
      # return Uint8Array...
    end}
  })
end)
```

The existing handler functions in `lib/quickbeam/` (URL, Fetch, Crypto, etc.) should be called directly — they already implement the native behavior. The JS polyfills just wrap these handlers with the Web API class interface.

## Files in Scope
- `lib/quickbeam/vm/runtime/globals.ex` — register new builtins
- `lib/quickbeam/vm/runtime/` — new modules for web API implementations
- `test/web_apis/beam_web_apis_test.exs` — test file (32 tests)

## Constraints
- Existing tests must still pass: `mix test test/vm/beam_compat_test.exs test/vm/compiler_test.exs`
- No new dependencies
- APIs should match browser behavior (the NIF tests in `test/web_apis/web_apis_test.exs` are the reference)

## Priority order (by test count and SSR importance)
1. TextEncoder/TextDecoder (5 tests) — used by every framework
2. URL/URLSearchParams (6 tests) — used by routers, fetch
3. atob/btoa (3 tests) — common utility
4. setTimeout/clearTimeout (2 tests) — framework internals
5. Headers (3 tests) — fetch dependency
6. AbortController (2 tests) — fetch dependency
7. performance.now (1 test) — profiling
8. Blob (2 tests) — fetch body
9. crypto (2 tests) — randomUUID, getRandomValues
10. fetch/Request/Response (3 tests) — network
