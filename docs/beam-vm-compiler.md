# BEAM VM Compiler

The BEAM VM compiler lowers QuickJS bytecode to BEAM modules. It is a BEAM-code compiler, not a native machine-code JIT and not an ECMA parse-node compiler.

## Pipeline

```text
JavaScript source
→ QuickJS-NG parser/compiler
→ QuickJS bytecode
→ QuickBEAM.VM.BytecodeParser / InstructionDecoder
→ Compiler.Optimizer
→ Compiler.Analysis.CFG / Stack / Types
→ Compiler.Lowering to Erlang abstract forms
→ BEAM module
→ Compiler.Runner invocation
→ RuntimeABI/shared semantic helpers for hard JavaScript behavior
```

## Semantic invariant

Compiled output must be observationally equivalent to interpreter output for supported bytecode.

Generated BEAM code may specialize JavaScript operations only when the inferred or guarded operand types make the BEAM operation observably equivalent to the ECMA-262 operation. Otherwise generated code must call `QuickBEAM.VM.Compiler.RuntimeABI` or shared semantic helpers.

Examples:

- integer arithmetic may lower to BEAM arithmetic only when representation and range assumptions preserve QuickBEAM number semantics;
- string concatenation may lower to binary concatenation only for known strings;
- property access should use ABI/helper paths unless object shape and key assumptions are guarded and invalidation-safe;
- operations that may call user code, throw, mutate objects/globals, enqueue jobs, or invalidate shapes must be modeled in compiler effects metadata.

## Spec boundary

The compiler does not directly implement ECMA-262 grammar productions. Clauses 11–16 are represented indirectly by QuickJS bytecode. Observable semantics are preserved by:

- `QuickBEAM.VM.Compiler.RuntimeABI`;
- `QuickBEAM.VM.Compiler.RuntimeHelpers` as the implementation adapter behind the ABI;
- `QuickBEAM.VM.ObjectModel.*`;
- `QuickBEAM.VM.Semantics.*`;
- `QuickBEAM.VM.Invocation`;
- `QuickBEAM.VM.GlobalEnvironment`;
- `QuickBEAM.VM.Promise`.

## Compiler clause map

| Compiler area | ECMA relationship |
|---|---|
| `Compiler` | bytecode-to-BEAM pipeline, cache, fallback policy |
| `Runner` | §7.3.13 Call, §7.3.14 Construct, §10.2 function call/construct setup |
| `Forms` | BEAM codegen, no direct ECMA clause |
| `Optimizer` | must preserve all observable JS semantics |
| `Analysis.Types` | compiler abstraction over §6.1 language types |
| `Lowering.Ops.Arithmetic` | §7.1 conversions, §7.2 comparisons, expression semantics |
| `Lowering.Ops.Calls` | §7.3.13 Call, §10.2 functions, eval/import call bytecode |
| `Lowering.Ops.Classes` | §15.7 classes, private elements, super |
| `Lowering.Ops.Control` | completion and abrupt-completion representation in bytecode control flow |
| `Lowering.Ops.Generators` | generator/async/await/yield semantics |
| `Lowering.Ops.Globals` | §9.1 environment records, §9.4 execution contexts, globals/TDZ |
| `Lowering.Ops.Iterators` | §7.4 iterator operations |
| `Lowering.Ops.Objects` | §7.3 object operations and §10 internal methods |
| `Lowering.Ops.WithScope` | object environment records / `with` behavior |
| `Lowering.Ops.Stack` | bytecode implementation detail, no direct spec analogue |
| `RuntimeABI` | stable generated-code boundary to semantic operations |
| `RuntimeHelpers` | compiled-code adapter to shared VM semantics |

## RuntimeABI boundary

Generated code should prefer `RuntimeABI` for spec-sensitive behavior. Direct calls to broad runtime helpers should remain compiler-private mechanics or migrate to the ABI when they become generated-code semantics.

Representative ABI mapping:

| ABI helper | ECMA relation |
|---|---|
| `to_object` | §7.1.18 ToObject |
| `to_property_key` | §7.1.19 ToPropertyKey |
| `copy_data_properties` | §7.3.25 CopyDataProperties |
| `get_field` | §7.3.2 Get, §10.1.8 [[Get]] |
| `put_field` | §7.3.4 Set, §10.1.9 [[Set]] |
| `for_of_start` | §7.4 iterator setup for bytecode |
| `iterator_next_result` | §7.4.6 IteratorNext |
| `iterator_close` | §7.4.11 IteratorClose |
| `assignment_with_iterator_close` | abrupt completion plus IteratorClose rules |

## Type analysis

Compiler abstract types are not ECMA language types exactly.

| Compiler type | ECMA relation |
|---|---|
| `:integer` | representation-specific Number subtype |
| `:number` | ECMA Number, including sentinel values depending on path |
| `:string` | ECMA String |
| `:boolean` | ECMA Boolean |
| `:object` | object reference, ordinary or exotic |
| `:function` | callable VM value |
| `:unknown` | top type |
| `{:shaped_object, ...}` | object with compiler-known layout assumptions |

## Fallback policy

Unsupported bytecode patterns fall back to the interpreter when correctness requires it. Known conservative fallback categories include mapped arguments and generator cleanup/resume patterns where preserving ECMA abrupt-completion and IteratorClose semantics requires state-machine reconstruction beyond current lowering.

## Effects model

`QuickBEAM.VM.Compiler.SemanticEffects` records semantic hazards for operations that can call user JavaScript, throw, mutate heap/global state, enqueue jobs, require iterator closing, or invalidate shape assumptions. Optimizations should consult and extend this metadata rather than assuming abstract operations are pure.
