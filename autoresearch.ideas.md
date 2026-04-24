# Autoresearch Ideas — 152 remaining failures (90.4%)

## Breakdown
- **47 with-statement scope** — insert3/perm4/put_ref_value opcodes
- **28 increment/decrement** — 21 unimplemented opcodes (with-scope), 7 evaluation order
- **18 for/dstr** — destructuring iterator, _isSameValue
- **8 try/dstr** — destructuring in catch
- **8 instanceof** — Symbol.hasInstance, prototype getter, var hoisting
- **8 delete** — _isSameValue (verifyProperty/Object.getOwnPropertyDescriptor), property descriptors
- **7 for** — var hoisting at eval scope
- **5 new** — spread iterator, _isSameValue
- **3 try** — catch shadowing, completion values
- **20 other** — surrogates (4), comparison (4), various

## Key blocker: _isSameValue through verifyProperty
Many remaining _isSameValue failures are from verifyProperty (propertyHelper.js) 
which uses Object.getOwnPropertyDescriptor. Our VM returns incomplete descriptors
or the descriptor check throws. Implementing Object.getOwnPropertyDescriptor
properly could fix ~15-20 tests.

## Key blocker: with-statement (47+21 = 68 tests)
Needs deep interpreter rewrite for scope chain management.

## Fixed this session
- op_apply[1] constructor apply globals refresh (8 tests!)
- call_constructor globals refresh (4 tests)
- Compiled cache key with constants hash (11 tests)
- Constructor identity (bare function wrapping, 10 tests)
- BigInt abstract_eq + neq (3 tests)
- delete_var builtin vs var-declared distinction
