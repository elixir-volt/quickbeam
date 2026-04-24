# Autoresearch — 138 remaining failures (91.3%)

## Overall: 628 → 138 = 490 tests fixed (78.0%)

## Remaining breakdown
- **68** with-statement scope + unimplemented opcodes — deep interpreter rewrite needed
- **~30** _isSameValue / closure identity — builtin property deletion, compiled cache edge cases
- **~18** destructuring iterator protocol — for-loop dstr, rest patterns
- **8** inc/dec evaluation order — null[prop()]++ TypeError vs DummyError  
- **7** instanceof — Symbol.hasInstance (3), prototype getter (2), other (2)
- **7** other — Unicode surrogates (4), private fields (2), proxy (1)

## Not fixable without deep changes
- with-statement scope chain (47 tests)
- Unimplemented opcodes insert3/perm4/put_ref_value (21 tests)
- Builtin property deletion (delete JSON.stringify doesn't work)
- Symbol.hasInstance in instanceof
- Private field syntax (#field in obj)
- Proxy objects
- Unicode surrogate comparison (UTF-8 vs UTF-16 code unit order)
