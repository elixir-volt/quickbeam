# Autoresearch Ideas — 68 remaining failures (95.7% pass rate)

## Session progress: 72 → 68 = 4 tests fixed

## Fixes this session
1. **CRITICAL: Stale catch_stack in opcode try/catch handlers** — `run(pc+1, ...)` inside BEAM `try` blocks prevents tail call optimization, so throws from ANY subsequent opcode are caught by stale catch clause with old `ctx.catch_stack`. Fixed by refreshing ctx from process dictionary in catch handlers. Also extracted `for_of_start`/`to_object`/`throw_error` throws to route through `throw_or_catch`. (4 tests)

## Previous session: 106 → 72 = 34 tests fixed
(See git history for details)

## Remaining breakdown (68 failures)
### Unfixable (~61)
- **45** with-statement scope (no `with` support in BEAM VM)
- **16** inc/dec using `with` in source (CRASHes/wrong scope)

### Potentially fixable (~7)
- **2** instanceof — `new Function` doesn't set constructor on prototype; `prototype` getter on Function.prototype not invoked during instanceof
- **2** private fields (`#field` syntax) — `in` operator for private field presence check
- **1** typeof/proxy — `typeof Proxy(function(){}, {})` returns "object" instead of "function"; Proxy needs to forward `[[Call]]`
- **1** delete — `delete this.y` returns true for declared vars; globalThis/variable binding mismatch
- **1** for-in/head-lhs-let — `let` as variable name in non-strict for-in; parser/lexer issue

## Dead ends (from previous sessions)
- `{:obj, _}` non-callable in instanceof: Function.prototype is {:obj, _} but callable
- collect_iterator with invoke_callback_or_throw: spread on undefined is valid, causes 4 regressions
- Destructuring null: catch clause binding was swallowing TypeError (now fixed via ctx refresh)

## Architecture notes
- BEAM try/catch prevents tail call optimization for `run(pc+1, ...)` inside try blocks
- Any opcode handler that wraps `run(pc+1, ...)` in try MUST refresh ctx from PD in catch clause
- The `catch_js_throw`/`catch_js_throw_refresh_globals` helpers are already correct (they extract results before calling `run`)
- The compiled path (RuntimeHelpers) uses BEAM try/catch from the lowering compiler, which properly scopes catch handlers
