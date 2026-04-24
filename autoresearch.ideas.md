# Autoresearch Ideas — 61 remaining failures (96.1% pass rate)

## Total progress: 72 → 61 = 11 tests fixed

## Fixes across all sessions
1. **Stale catch_stack in opcode try/catch handlers** — refresh ctx from PD in catch clauses (4 tests)
2. **delete this.y for declared vars** — define_var syncs to globalThis with configurable:false (1 test)
3. **Function.prototype.constructor** — added constructor to proto_property chain (1 test)
4. **typeof for proxies** — delegates to proxy target + added Proxy.revocable (1 test)
5. **check_prototype_chain for arrays** — arrays/qb_arr now match Array/Object prototype (1 test)
6. **Class field initializer capture** — eval_with_ctx now calls setup_captured_locals (1 test)
7. **private_in for accessors** — check brand in addition to field presence (1 test)
8. **Array prototype setter + globals refresh** — put_element checks Array.prototype for OOB setters, put_array_el refreshes persistent globals (1 test)

## Remaining breakdown (61 failures)
### All unfixable without `with` scope implementation
- **45** with-statement scope (no `with` support in BEAM VM)
- **16** inc/dec using `with` in source (stack opcodes fail with wrong scope)

### No more fixable tests
All non-with test262 failures have been resolved. The remaining 61 failures all require full `with` statement scope implementation, which would need:
- Object environment records
- Scope chain with `with` binding layer
- `with_get_var`/`with_put_var` proper scope resolution
- `Symbol.unscopables` support
- Stack opcode (insert3/perm4) correct stack depth in `with` context

## Dead ends
- `with` scope: Would require full environment record refactor (100+ opcodes affected)
- `Function.prototype` typeof: Returns "object" instead of "function"
- toPrimitive side effects: Closure vars captured by copy, not reference (partially mitigated by persistent_globals refresh)
