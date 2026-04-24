# Autoresearch Ideas — 47 remaining failures (96.9% pass rate)

## Total progress: 72 → 47 = 25 tests fixed

## Key fixes
1. **Stale catch_stack** — refresh ctx from PD in catch clauses (4 tests)
2. **delete this.y** — configurable:false for declared vars (1 test)
3. **Function.prototype.constructor** — proto_property chain (1 test)
4. **typeof proxy** — delegates to target + Proxy.revocable (1 test)
5. **instanceof for arrays** — Array/Object.prototype check (1 test)
6. **Class field capture** — eval_with_ctx setup_captured_locals (1 test)
7. **private_in for accessors** — brand check (1 test)
8. **Array proto setter** — OOB put_element + globals refresh (1 test)
9. **make_*_ref 2-value push** — prop_name + cell (eliminates 23 crashes)
10. **with_has_property?** — has_property instead of Get.get (14 tests!)
11. **with_make_ref compiler fallback** — force interpreter for with-scope functions

## Remaining breakdown (47 failures, all with-scope)
- **15** not a function — function calls through `with` scope use different opcodes
- **6** p5 is not defined — var declarations inside `with` don't leak to outer scope
- **6** undefined is not a constructor — constructor calls through `with`
- **6** Expected ReferenceError — strict mode ref errors in `with`
- **14** misc with-scope issues (unscopables, property access, scope close)

## Potential next steps
- **Function calls in `with`**: The `with_get_var` resolves reads but function CALLS may use different bytecode paths. Need to check if `call_function` looks up through `with` scope.
- **var creation in `with`**: When `p5 = 'x5'` runs inside `with(myObj)` and `myObj` doesn't have `p5`, it should create a global `p5`. The `with_put_var` fallthrough should handle this.
