# Autoresearch Ideas

- Add a compact failure-clustering helper for `bench/vm_compiler_test262.exs` that groups failures by message prefix and filename stem to pick structurally large clusters before individual cases.
- Build a small direct-eval parity probe for object accessor descriptor cases to compare native bytecode interpreter vs source-compiled eval output without the full Test262 harness.
- Audit object literal `__proto__` handling across parser/source compiler/QuickJS bytecode interpreter/object model; many remaining object failures are shared `__proto__-*` semantics.
- Audit accessor property key normalization for computed and numeric keys; remaining accessor-name failures suggest getters/setters may be defined under a non-canonical key or skipped during computed key conversion.
