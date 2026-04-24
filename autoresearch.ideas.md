# Autoresearch Ideas — 64 remaining failures (95.8% pass rate)

## Session progress: 72 → 64 = 8 tests fixed

## Fixes this session
1. **Stale catch_stack in opcode try/catch handlers** — refresh ctx from PD in catch clauses (4 tests)
2. **delete this.y for declared vars** — define_var syncs to globalThis with configurable:false (1 test)
3. **Function.prototype.constructor** — added constructor to proto_property chain (1 test)
4. **typeof for proxies** — delegates to proxy target + added Proxy.revocable (1 test)
5. **check_prototype_chain for arrays** — arrays/qb_arr now match Array/Object prototype (1 test)

## Remaining breakdown (64 failures)
### Unfixable (~61)
- **45** with-statement scope (no `with` support in BEAM VM)
- **16** inc/dec using `with` in source

### Potentially fixable (~3)
- **2** private fields (`#field` syntax) — `in` operator for private field presence check; class field initialization
- **1** for-in/head-lhs-let — member expression LHS `[let][1]` setter not called in for-in loop

## Dead ends
- `with` statement scope — would require full with-scope implementation (114+ opcodes)
- `Function.prototype` typeof — returns "object" instead of "function"; deep issue
- Array prototype chain in heap — arrays stored as lists lack proto() key

## Architecture notes
- BEAM try/catch prevents tail call optimization for `run(pc+1, ...)` inside try blocks
- Any opcode handler that wraps `run(pc+1, ...)` in try MUST refresh ctx from PD in catch clause
- Closures lack heap-backed prototype chain; `proto_property` provides virtual properties
