# Autoresearch Ideas — 13 remaining failures (99.2% pass rate)

## Total progress: 72 → 13 = 59 tests fixed (81.9% reduction)

## Key fixes this session
1. **put_ref_value global sync** — cell writes now always sync to ctx.globals/globalThis (-33 tests!)
2. **Symbol.unscopables** — added symbol, unscopables check in with_has_property?, shaped object symbol-key storage (-1 test)

## Remaining breakdown (13 failures)
- **4** inc/dec putvalue strict mode — `delete` binding + strict access should throw ReferenceError
- **3** S12.10_A1.7 — `this.p2='x2'` in callback doesn't propagate to caller's globals context
- **3** unscopables binding deletion — complex Symbol.unscopables + delete + strict mode interaction
- **1** has-property-err — Proxy `has` trap should throw
- **1** unscopables-inc-dec — unscopables with inc/dec ops
- **1** typed-array strict mode — strict mode binding deletion

## Remaining issues analysis
- **Callback globals propagation** (3 tests): Function calls via Invocation.invoke create isolated contexts. Writes to `this.p2` modify globalThis in heap but don't sync back to caller's ctx.globals. Need globals refresh after call_method/call_function opcodes.
- **Strict mode ReferenceError** (5 tests): Deleting a binding then accessing it in strict mode should throw ReferenceError. Need strict mode enforcement in with-scope set/get operations.
- **Proxy has trap** (1 test): with_has_property? should support Proxy `has` trap.
- **Unscopables + inc/dec** (2 tests): Complex interaction of unscopables check with increment/decrement and binding deletion.
