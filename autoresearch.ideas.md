# Autoresearch Ideas

## Deferred Optimizations

- **F.prototype = value sync to class_proto**: Need to only apply for user-defined closures, NOT builtins (Array/Number/String/Boolean). Discriminate by checking `ctor` type: `{:closure, _, _}` vs `{:builtin, _, _}`.
- **for-in prototype value access**: Keys from prototype are enumerated but values return undefined inside for-in loop. Might be a scope/context issue in the for-in body.
- **Error constructor identity across invocations**: 72 tests still fail due to closure identity across nested invoke_with_receiver. Fixed get_or_create_prototype (no more constructor update on cache hit) and catch_js_throw_refresh_globals catch path refresh. Remaining failures are from deeper nesting through assert.throws.
- **Destructuring in for initializer**: `for (var [x] = iter; ...)` doesn't trigger iterator protocol on `iter`.
- **Variable hoisting in labeled loops**: `break label; var x = 1` — variable `x` should still be hoisted (value=undefined).
- **Symbol.iterator on arrays**: `Array.prototype[Symbol.iterator]` returns undefined.
- **with-statement scope**: 47 tests blocked — insert3/perm4/put_ref_value opcodes fail when stack doesn't have enough elements.
- **for-in mid-iteration deletion**: for-in should skip properties deleted during iteration. Currently snapshots keys at start.
- **Unicode surrogate comparison**: \uD800 < \uDC00 fails — Elixir binary comparison doesn't match JS code unit comparison.
- **var hoisting at global scope**: `var x; void x` at top-level eval doesn't hoist the var properly.
