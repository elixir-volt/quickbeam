# Autoresearch Ideas — 4 remaining failures (99.7% pass rate)

## Total progress: 72 → 4 = 68 tests fixed (94.4% reduction)

## Remaining 4 failures
All require getter side effect propagation (closure var mutations from accessor callbacks):

1. **unscopables-inc-dec** — @@unscopables getter count assertion
2. **get-mutable-binding-binding-deleted-in-get-unscopables** — @@unscopables getter count 
3. **set-mutable-binding-binding-deleted-in-get-unscopables** — same issue
4. **has-property-err** — Proxy `has` trap (assert.throws not found — likely a test harness issue)

## Root cause of remaining failures
All 3 unscopables tests track how many times an accessor getter is called (`count++` inside getter). The getter updates a captured outer variable, but the update doesn't propagate back because:
- Getter runs via `Get.get` → `call_getter` → `Invocation.invoke_with_receiver`
- `count++` uses `put_var` which syncs to `persistent_globals`
- But the caller of `call_getter` doesn't refresh from `persistent_globals`
- So the outer scope's `ctx.globals` still has the old `count` value

The `has-property-err` test likely fails because `assert.throws` isn't resolved — possibly a test harness includes issue.

## Dead ends
- **Bulk globalThis refresh**: Caused 31 regressions (stale data overwrites)
- **toPrimitive side effects**: Same fundamental issue — closure captures don't propagate
