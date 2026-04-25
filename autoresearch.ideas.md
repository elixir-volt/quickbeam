# Autoresearch Ideas

## Status: All 311 beam-mode web API tests pass (0 failures)

## Completed
- performance.mark/measure/getEntries ✅
- FormData with File support, iteration ✅
- EventTarget, Event, CustomEvent, DOMException ✅
- AbortSignal static methods (abort/timeout/any), throwIfAborted ✅
- Blob.text()/arrayBuffer()/slice(), File constructor ✅
- ReadableStream with getReader, async iterator ✅
- Enhanced Headers (forEach/entries/keys/values, array init) ✅
- fetch body consumption (text/json/arrayBuffer/bytes), clone ✅
- Response.json/redirect/error static methods ✅
- URL property setters (pathname/search/hash/hostname/port) ✅
- URLSearchParams size, sort, forEach, Symbol.iterator, from array/object ✅
- BroadcastChannel in-process pub/sub ✅
- GC roots for global cache (fixes randomUUID between evals) ✅
- for-await-of Symbol.asyncIterator support ✅
- AbortSignal timeout via timer queue ✅
- maybe_wrap_async: while/try-catch return value injection ✅

## Potential future improvements
- PerformanceObserver (not tested)
- WritableStream/TransformStream full implementations (stubs in place)
- BroadcastChannel cross-process (using pg groups for multi-runtime tests)
- Streams pipeTo/pipeThrough
