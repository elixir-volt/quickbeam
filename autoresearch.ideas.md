# Autoresearch Ideas — 111 remaining failures (93.0%)

## Overall: 628 → 111 = 517 tests fixed (82.3%)

## Session progress: 133 → 111 = 22 tests fixed

## Remaining breakdown (111 failures)
- **47** with-statement scope — deep interpreter rewrite needed (unfixable)
- **~15** _isSameValue — systemic assert.sameValue issue (closure identity or error propagation)
- **15** for/dstr — destructuring iterator protocol not invoked
- **7** try/dstr — similar destructuring issues
- **6** instanceof — 3 Symbol.hasInstance getter, 2 prototype getter, 1 eval order
- **4** unicode — surrogate comparison (UTF-8 vs UTF-16, unfixable in Elixir)
- **4** new/spread — iterator with defineProperty getters
- **3** try/finally — completion values (finally runs multiple times across function boundaries)
- **2** private fields — unimplemented
- **2** addition — Symbol.toPrimitive with defineProperty getter
- **1** proxy — unimplemented
- **1** delete this.y — var declarations not reflected on globalThis

## Not fixable without deep changes
- with-statement scope chain (47 tests) — needs insert3/perm4/put_ref_value/with_*
- Unicode surrogate comparison (4 tests) — Elixir UTF-8 binary comparison
- Private fields (2 tests) — #field in obj syntax
- Proxy (1 test)
- var declarations on globalThis (1 test)

## High-value fixes to investigate
- **Object.defineProperty with symbol keys + getters**: Would fix ~15 tests (Symbol.toPrimitive getter, instanceof getter, spread iterator getter). Requires proper property descriptor model for symbol-keyed properties.
- **try/finally double-execution**: When catch body throws across function boundaries, the finally block runs multiple times. Root cause: gosub/ret/throw sequence interacts with the catch_stack from the calling function's try-catch. Would fix 3 tests.
- **Destructuring iterator protocol**: `for (var [x] = iter; ...)` and `catch({ w: [x] }) {}` don't invoke Symbol.iterator. Would fix ~22 tests.
- **_isSameValue systemic**: Many tests fail because assert.sameValue internally throws. Root cause unclear — might be related to how closures/builtins are compared across evaluation contexts.
