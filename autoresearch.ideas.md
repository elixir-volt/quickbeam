# Autoresearch Ideas — 13 remaining failures (99.2% pass rate)

## Total progress: 72 → 13 = 59 tests fixed (81.9% reduction)

## This session's key fixes
1. **put_ref_value global sync** — cell writes always sync to ctx.globals/globalThis/persistent_globals (-33 tests!)
2. **Symbol.unscopables** — added symbol, unscopables check in with_has_property?, shaped object symbol-key storage (-1 test)

## Remaining 13 failures
- **3** S12.10_A1.7 — `this.p2='x2'` in callback doesn't propagate to caller's ctx.globals
- **4** inc/dec putvalue strict mode — ReferenceError for deleted with-scope bindings  
- **3** unscopables binding deletion — delete + unscopables + strict mode interaction
- **1** has-property-err — Proxy `has` trap should throw in with_has_property
- **1** unscopables-inc-dec — unscopables with inc/dec ops
- **1** typed-array strict mode — binding deletion with typed array in prototype chain

## Dead ends this session
- **refresh_globals from globalThis**: Caused 31 regressions. globalThis contains stale data that overwrites newer values from put_var. Need targeted sync only for properties actually modified by callee, not a bulk refresh.

## Potential approaches for remaining tests
- **this.p2 issue**: `put_field` on globalThis should write to persistent_globals when the key is a known global variable. This is targeted (won't regress) but requires checking if obj === globalThis in put_field.
- **Strict mode ReferenceError**: with_put_var needs strict mode enforcement — throw ReferenceError when binding was deleted during unscopables check.
- **Proxy has trap**: with_has_property? should call Proxy `has` trap for proxy objects.
