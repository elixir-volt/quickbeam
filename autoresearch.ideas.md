# Autoresearch Ideas

## High Impact (if solvable)

- **Closure identity in invoke_with_receiver** (~55 tests): The fundamental issue is that `GlobalEnv.refresh` calls `Map.merge(prev.globals, persistent)` which can introduce term references that differ from the original ctx.globals. When a function throws through catch_js_throw_refresh_globals, the error's constructor (set from the callback's ctx) differs from the expectedCtor argument (from the caller's ctx). Would need to track and preserve exact Erlang term identity across Map.merge operations, or change how prototypes store constructor references.

- **with-statement scope** (~68 tests): The with-statement pushes a scope object onto the scope chain. The bytecode uses insert3/perm4/put_ref_value opcodes that expect a specific stack layout. These opcodes ARE implemented but fail because the with-statement doesn't set up the stack correctly. Would need deep changes to how with-blocks manage the evaluation stack.

## Medium Impact

- **Destructuring in for initializer** (~6 tests): `for (var [x] = iter; ...)` doesn't trigger iterator protocol.
- **Variable hoisting at eval scope** (~4 tests): `var` declarations inside nested for loops aren't hoisted to the eval scope.
- **Unicode surrogate comparison** (4 tests): Elixir UTF-8 binary comparison doesn't match JS UTF-16 code unit comparison for lone surrogates.
- **Symbol.hasInstance** (3 tests): instanceof should check @@hasInstance before callable check.
- **for-in mid-iteration deletion** (1 test): Keys deleted during iteration should be skipped.
- **catch variable shadowing** (1 test): Nested try/catch with same variable name in catch clause.

## Low Impact / Won't Fix

- **Property descriptors** (2 tests): delete Math.E / delete this.y — non-configurable properties.
- **Private fields** (2 tests): `#field in obj` syntax not implemented.
- **Function.prototype callable** (1 test): Function.prototype is a special callable non-function object per spec.
