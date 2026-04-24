# Autoresearch Ideas — 106 remaining failures (93.3%)

## Session progress: 133 → 106 = 27 tests fixed

## Remaining breakdown (106 failures)
### Unfixable without deep changes (~71)
- **47** with-statement scope — deep interpreter rewrite needed
- **16** inc/dec using with-scope in test source — also unfixable
- **4** unicode surrogate comparison — UTF-8 vs UTF-16
- **2** private fields — #field in obj
- **1** proxy — not implemented
- **1** delete this.y — var declarations not on globalThis

### Potentially fixable (~35)
- **~15** for/dstr + try/dstr — destructuring iterator protocol not invoked
- **~8** _isSameValue — systemic assert.sameValue issue (defineProperty getters needed)
- **~4** instanceof — closure identity, prototype getter on Function.prototype
- **~3** try/finally — completion values (finally double-execution across function calls)
- **~4** new/spread — iterator with defineProperty getters + timeout
- **~1** unsigned-right-shift BigInt toPrimitive eval order

## Completed fixes this session
1. dup2/dup3 stack corruption (4 tests)
2. Spread property enumeration + __key_order__ (1 test)
3. Destructuring rest pattern exclusion (4 tests)
4. for-in: skip deleted properties during enumeration (1 test)
5. Symbol.hasInstance in instanceof (1 test)
6. BigInt TypeError with Heap.make_error (1 test)
7. Builtin property deletion (configurable methods vs non-configurable constants) (2 tests)
8. Array element delete (sparse arrays) (2 tests)
9. for-in: non-enumerable own properties shadow prototype keys (1 test)
10. to_propkey2 null/undefined check (8 tests)
11. instanceof OrdinaryHasInstance spec order (1 test)
12. abstract_eq Symbol × Object ToPrimitive (1 test)
13. defineProperty symbol keys + accessor in ToPrimitive (2 tests)
14. instanceof namespace objects not callable (1 test)
15. Values.div/2 wrapper for compiler

## Dead ends
- **{:obj, _} non-callable in instanceof**: Too aggressive — Function.prototype is {:obj, _} but callable. 4 regressions.
