# Autoresearch Ideas — Web API Builtins

## STATUS: COMPLETE - 0/92 failing

All 92 beam web API tests pass. 

## What was fixed
- TextEncoder encodeInto + lone surrogate (WTF-8) handling
- TextDecoder proper UTF-8 decode, fatal mode, BOM, ArrayBuffer input
- atob/btoa type coercion, whitespace, padding
- crypto.getRandomValues: zero-length and >65536 fixes
- performance.now: positive ms relative to session start
- queueMicrotask: TypeError for non-function, silent error discard
- structuredClone: full deep clone for all structured-cloneable types
- Timers: actual timer execution via macro task queue + drain_pending loop
- Promise constructor: executor called with resolve/reject builtins
- String spread operator: iterate UTF-8 codepoints correctly
- Top-level await: async IIFE wrapper in eval_beam
- Map constructor: handle qb_arr-backed inner arrays
- instanceof: auto_proto for Date/RegExp/Map/Set/ArrayBuffer
- get_prototype_raw: type-specialized methods before proto chain
