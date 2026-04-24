# Autoresearch Ideas — 139 remaining failures (91.2%)

## Breakdown  
- **47 with-statement** — scope chain management, opcodes
- **28 inc/dec** — unimplemented opcodes (21), evaluation order in args (7)
- **18 for/dstr** — destructuring iterator, _isSameValue (verifyProperty)
- **8 try/dstr** — destructuring in catch
- **8 delete** — _isSameValue, property descriptors
- **7 instanceof** — Symbol.hasInstance, prototype getter
- **5 new** — spread iterator errors, _isSameValue
- **18 other** — surrogates, private fields, proxy, _isSameValue misc

## Key blockers
1. **with-statement** (47+some inc/dec = ~68): Deep interpreter rewrite
2. **_isSameValue through verifyProperty** (~12): Object.getOwnPropertyDescriptor 
   returns correct values but verifyProperty from propertyHelper.js fails for
   spread-created objects
3. **x[0]++ as function argument** (4): BigInt post-increment in call arg position
   fails with "not a function"
4. **Destructuring iterator protocol** (~18): for-loop destructuring doesn't
   trigger iterator, rest pattern doesn't exclude named props

## Session achievements (152 → 139)
- var hoisting: define_var now updates ctx.globals (13 tests!)
- op_apply[1] constructor apply refresh (8 tests)
- call_constructor + op_apply refresh (4 tests)
- delete_var builtin distinction

## Overall: 628 → 139 = 489 tests fixed (77.9%), 91.2% pass rate
