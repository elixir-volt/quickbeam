# Autoresearch Ideas — 96 remaining failures (93.9%)

## Session progress: 106 → 96 = 10 tests fixed

## Fixes this session
1. **CRITICAL: Shape key ordering in wrap_keyed** — lowering sort_by pattern didn't match :erl_parse.abstract binary AST format (3 tests)
2. **from_map vals ordering** — build vals in shape offset order instead of map iteration order
3. **Iterator error propagation** — invoke_callback_or_throw replaces call_callback in for_of_start/next/iterator_next (5 tests)
4. **Spread iterator accessor descriptors** — handle defineProperty getter on Symbol.iterator (2 tests)
5. **Spread TypeError for non-object iterator** — per spec 7.4.1 step 3 (1 test)

## Remaining breakdown (96 failures)
### Unfixable (~63)
- **47** with-statement scope
- **16** inc/dec using with in source (CRASHes)

### Potentially fixable (~33)
- **~13** _isSameValue — systemic assert.sameValue issue
- **~7** for/dstr — array-prototype iterator override, rest-getter
- **~7** try/dstr — similar + null destructuring
- **~4** instanceof — closure identity, prototype getter
- **~3** try/finally — double execution across function boundaries
- **~4** unicode surrogates — UTF-8 vs UTF-16 (may be unfixable)
- **~2** spread timeout — value getter on iterator result
- **~2** private fields — #field syntax
- **~1** proxy, ~1 typeof/proxy, ~1 delete this.y, ~1 unsigned-right-shift

## Dead ends
- `{:obj, _}` non-callable in instanceof: Function.prototype is {:obj, _} but callable
- collect_iterator with invoke_callback_or_throw: spread on undefined is valid, causes 4 regressions
- Destructuring null: for_of_start throws TypeError but it's caught and swallowed by the error propagation machinery
