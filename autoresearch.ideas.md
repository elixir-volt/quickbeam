## Remaining 6 failures (92→6, -93.5%)

### Unsupported (2)
- `with(o){ delete x; }` — needs with-scope semantics (`with_get_var`, `with_put_var`, `with_delete_var`)
- `test/vm/test_language.js` — needs declarations for AssignmentPattern defaults in function params, `async` class fields in factory path

### Mismatches (4)
- `Symbol.iterator` custom iterable — interpreter+BEAM correct (3), but native_load fails ("not a function" — for_of_start uses internal atom lookup for Symbol.iterator)
- `eval('arguments[0]')` — inherent limitation of indirect eval (no access to caller scope)
- Computed super destructuring `({[p]: super.x} = {a:1})` — native load fails (atom reference leak in bytecode writer)
- Derived constructor `super(); return {x:1}` — factory path can't mark is_derived_class_constructor, needs super() in define_class path

### All 4 mismatches blocked by native_load issues
Interpreter and BEAM compiler now produce correct results for 2/4 mismatch cases (Symbol.iterator, possibly computed super). The metric doesn't improve because native_load must also match.
