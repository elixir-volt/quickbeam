# Autoresearch Ideas — 164 remaining failures (89.6%)

## Breakdown
- **47 with-statement scope** — insert3/perm4/put_ref_value opcodes, scope chain management
- **28 increment/decrement** — 21 unimplemented opcodes (with-scope), 7 evaluation order
- **18 for/dstr** — destructuring iterator protocol, closure identity
- **17 new/spread** — mostly _isSameValue closure identity through spread
- **8 try/dstr** — destructuring in catch, closure identity
- **8 instanceof** — Symbol.hasInstance, prototype getter
- **8 delete** — 6 _isSameValue, 2 property descriptors (Math.E, this.y)
- **7 for** — var hoisting at eval scope (4), for-in deletion (1), other (2)
- **3 try** — catch variable shadowing, completion values, closure identity
- **2 addition** — Symbol.toPrimitive getter, closure identity
- **2 do-while** — var hoisting in labeled break
- **16 other** — Unicode surrogates (4), typeof proxy (1), various edge cases

## Fixed root causes (key learnings)
1. Compiled module cache keyed only by bytecode — missed constants (11 tests!)
2. Bare Bytecode.Function vs closure tuple in get_or_create_prototype (10 tests!)
3. Constructor update on prototype cache hit corrupted identity (21 tests!)
4. to_primitive: own valueOf/toString type checking, null as own property
5. String fast path in add bypassed ToPrimitive
6. isNaN/Math.floor didn't handle Infinity atoms

## Dead ends
- delete_var pre_eval_keys: function declarations also appear in pre-eval context
- Sub ToPrimitive-both-first: wrong per spec evaluation order
- GlobalEnv.refresh identity preservation: doesn't address root cause
