# Autoresearch Ideas — Web API Builtins

## Approach
Implement each missing API as a native BEAM builtin. Use existing Elixir stdlib where possible.

## Currently passing (38/92)
TextEncoder, TextDecoder, URL, URLSearchParams, atob, btoa, crypto.getRandomValues, performance.now, queueMicrotask, structuredClone, console, setTimeout/clearTimeout

## Likely failing categories
- encodeURIComponent/decodeURIComponent/encodeURI/decodeURI — missing globals
- crypto.randomUUID — may need format fix
- Detailed TextEncoder/TextDecoder edge cases
- Timer callback execution (setTimeout actually running callbacks)
