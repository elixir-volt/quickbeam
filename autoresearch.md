# Autoresearch: test262 Conformance

## Objective
Maximize the number of passing ECMAScript test262 tests in the QuickBEAM BEAM VM (interpreter + compiler). The VM executes JS bytecode compiled by QuickJS-NG. Tests that also fail on the native QuickJS NIF are skipped (909 tests).

## Metrics
- **Primary**: `failing_tests` (count, lower is better) — number of test262 failures
- **Secondary**: `passing_tests`, `skipped_tests`, `run_time_s`

## How to Run
`./autoresearch.sh` — runs `MIX_ENV=test mix test test/vm/test262_test.exs --include test262 --max-cases 8` and parses the result line.

## Files in Scope
- `lib/quickbeam/vm/interpreter.ex` — bytecode interpreter main loop
- `lib/quickbeam/vm/interpreter/values.ex` — JS type coercion, arithmetic, comparisons
- `lib/quickbeam/vm/object_model/get.ex` — property read (Get.get, get_own, prototype chain)
- `lib/quickbeam/vm/object_model/put.ex` — property write, has_property, delete
- `lib/quickbeam/vm/invocation.ex` — function call dispatch, invoke_with_receiver
- `lib/quickbeam/vm/runtime/` — builtin JS objects (Math, Number, Array, etc.)
- `lib/quickbeam/vm/heap.ex` — object heap, wrap, GC
- `lib/quickbeam/vm/compiler/` — bytecode-to-BEAM compiler (lowering, forms, runtime_helpers)
- `test/support/test262.ex` — test262 helper module
- `test/vm/test262_test.exs` — ExUnit test generator
- `test/test262_skip.txt` — skip list (NIF failures)

## Off Limits
- `priv/c_src/` — C source (QuickJS-NG)
- `lib/quickbeam/vm/bytecode.ex` — bytecode decoder (except BigInt which was already fixed)
- Performance must not regress on the Preact SSR benchmark (~3ms target)

## Constraints
- `MIX_ENV=test mix test test/vm/beam_compat_test.exs test/vm/compiler_test.exs` must pass (396 tests, 0 failures)
- No new dependencies

## Remaining Failure Categories (308 failures)
1. **with statement scope (64)** — `p1/f is not defined`: global `this` property not bridged to vars
2. **toPrimitive side effects (47)** — `_isSameValue threw [object Object]`: closure var mutations inside valueOf/toString callbacks don't propagate back to caller scope
3. **Error constructor identity (17)** — `different error constructor with same name`: compiled closure constructor identity differs across invocation contexts
4. **TypeError vs Test262Error (19)** — wrong error type thrown for destructuring null, non-callable RHS
5. **Not a function (19)** — missing prototype methods, `this` binding in non-strict mode
6. **Cannot convert object to primitive (15)** — Object(1n) BigInt wrapper toPrimitive needs BigInt.prototype
7. **Stack opcodes (21)** — perm4/insert3 with complex with+increment patterns
8. **instanceof prototype (7+5)** — builtin prototypes not configured for Boolean/Number/String
9. **Misc (195)** — evaluation order, infinity edge cases, delete non-configurable

## What's Been Tried
- **BigInt decoding**: Fixed two's complement bytecode reading. +45 tests.
- **BigInt ops**: Added bitwise, comparison, inc/dec, mixed-type errors. +~60 tests.
- **toPrimitive in add**: Object coercion via valueOf/toString. +5 tests.
- **to_number via toPrimitive**: Objects call valueOf then toString. +3 tests.
- **make_loc_ref arg parsing**: atom_u16 format gives [atom_idx, var_idx], not [idx]. +45 crash fixes.
- **make_var_ref opcode**: Global scope variable reference lookup. +21 tests.
- **Infinity comparisons**: numeric_compare handles :infinity/:neg_infinity atoms. +31 tests.
- **Float overflow**: safe_add/safe_mul with sign detection. +6 tests.
- **Number.MAX_VALUE**: Missing constant added. +10 tests.
- **new/instanceof validation**: Constructor checks, prototype chain. +16 tests.
- **in operator**: Prototype chain lookup, TypeError for primitives. +5 tests.
- **Function.prototype.toString**: Source for closures, [native code] for builtins. +6 tests.
- **BigInt.toString/valueOf**: Methods on bigint values. Fixes template literals.
- **typeof namespace objects**: Math/JSON return "object" not "function". +2 tests.
- **catch_js_throw for all operators**: valueOf throws inside try/catch now caught properly. +14 tests.
- **Symbol.toPrimitive**: to_primitive checks @@toPrimitive first.
- **abstract_eq infinity/NaN**: Explicit clauses for special values. +4 tests.
- **Iterator null/undefined**: for-of/destructuring throws TypeError. +7 tests.
- **Builtin .name property**: get_own returns builtin name for "name" key.
- **Prototype chain for new**: get_or_create_prototype sets __proto__ to Object.prototype. +2 tests.
- **Global this binding**: Set this=globalThis in eval context + get_var fallback to globalThis properties. +51 tests.
- **get_var_undef/put_var globalThis**: Sync variable access through globalThis object. +1 test.
- **delete_var returns false**: var declarations are non-configurable. +3 tests.
- **to_object TypeError**: Throws TypeError for null/undefined (was no-op). +8 tests.
- **Function.prototype auto-setup**: auto_proto for Function constructor. +1 test.
- **Wrapped object primitives**: Object(1n/42/"str"/true) wrapping + to_primitive/stringify for __wrapped_* keys. +17 tests.
- **Delete on function statics**: delete F.prop removes from ctor_statics. +1 test.
- **NaN is falsy**: truthy?(:nan) = false. +7 tests.
- **Negative zero falsy**: truthy?(-0.0) = false. +1 test.
- **typeof :neg_infinity**: Returns "number" (was falling to "object"). +1 test.
- **isNaN/isFinite coercion**: Convert non-number args via to_number. +1 test.
- **BigInt vs infinity/NaN comparisons**: Explicit clauses for all comparison operators. +4 tests.
- **Object.defineProperties**: New static method.
- **stringify for functions**: Functions return source or [native code] (was "[object]").
- **to_primitive for functions**: Functions return source string from to_primitive.
- **DEAD END: auto_proto for Boolean/Number/String/Array**: Caused 5-8 regressions.
- **DEAD END: auto_proto for builtins**: Caused 8 regressions in try/throw/logical-not tests.
  Object.prototype not available during globals init. Reverted.
- **DEAD END: toPrimitive side effects**: Closure var mutations don't propagate.
  Root cause is closure capture semantics — vars are captured by copy, not by reference.
  Would need deep interpreter refactor to thread context through Values.add → to_primitive.
