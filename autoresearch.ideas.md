# Autoresearch Ideas — 62 remaining failures (96.0% pass rate)

## Session progress: 72 → 62 = 10 tests fixed

## Fixes across sessions
1. **Stale catch_stack in opcode try/catch handlers** — refresh ctx from PD in catch clauses (4 tests)
2. **delete this.y for declared vars** — define_var syncs to globalThis with configurable:false (1 test)
3. **Function.prototype.constructor** — added constructor to proto_property chain (1 test)
4. **typeof for proxies** — delegates to proxy target + added Proxy.revocable (1 test)
5. **check_prototype_chain for arrays** — arrays/qb_arr now match Array/Object prototype (1 test)
6. **Class field initializer capture** — eval_with_ctx now calls setup_captured_locals (1 test)
7. **private_in for accessors** — check brand in addition to field presence (1 test)

## Remaining breakdown (62 failures)
### Unfixable (~61)
- **45** with-statement scope (no `with` support in BEAM VM)
- **16** inc/dec using `with` in source

### Potentially fixable (~1)
- **1** for-in/head-lhs-let — member expression LHS `[let][1]` setter not invoked; requires OrdinarySet with prototype chain setter support for arrays

## Dead ends
- Array prototype setter in `put_element`: complex — arrays use `:qb_arr` format, not maps. Need to trace exact bytecode path + implement setter lookup from actual `Array.prototype` object in heap.
- `with` statement scope: would require full with-scope implementation (114+ opcodes)
- `Function.prototype` typeof: returns "object" instead of "function"
