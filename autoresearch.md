# Autoresearch: JS Bytecode Compiler Frontier

## Objective
Expand the separate frontend compiler:

```text
QuickBEAM.JS.Parser AST -> QuickBEAM.JS.BytecodeCompiler -> %QuickBEAM.VM.Bytecode{} -> QuickBEAM.VM.Bytecode.Writer -> QuickJS-loadable bytecode binary
```

The goal is to reduce unsupported/mismatching cases in a curated JavaScript bytecode compiler frontier while preserving the already-clean compatibility audit. QuickJS is the reference implementation: every frontier case is evaluated natively with QuickJS through QuickBEAM, then compared against the new compiler's interpreter path, BEAM compiler path, and native `load_bytecode/2` path.

Do not cheat by special-casing benchmark strings, suppressing unsupported errors, editing benchmark inputs to make the metric easier, bypassing QuickJS validation, or fabricating loadability. Fix generic bytecode compiler, writer, scope, or VM semantics.

## Primary Metric
- **`js_bytecode_frontier_failures`** (lower is better): count of frontier cases that are unsupported, compile errors, mismatches against QuickJS, or not QuickJS-loadable.

## Secondary Metrics
- `js_bytecode_frontier_cases` — fixed frontier size for this phase.
- `js_bytecode_frontier_compiled` — frontier cases that compile to `%QuickBEAM.VM.Bytecode{}`.
- `js_bytecode_frontier_unsupported` — compiler gaps returning `{:unsupported, ...}`.
- `js_bytecode_frontier_mismatches` — cases that compile but disagree with QuickJS/interpreter/BEAM compiler/native-load.
- `js_bytecode_frontier_native_loadable` — compiled frontier cases whose emitted binary loads through QuickJS with the expected result.
- `js_bytecode_compiler_cases` — stable regression audit size.
- `js_bytecode_compiler_failures` — must stay `0`.
- `js_bytecode_compiler_mismatches` — must stay `0`.
- `js_bytecode_compiler_native_loadable` — must equal `js_bytecode_compiler_cases`.

## Commands
Run the frontier loop with:

```sh
./autoresearch.sh
```

Useful options:

```sh
JS_BYTECODE_FRONTIER_FAILURE_LIMIT=20 ./autoresearch.sh
```

`autoresearch.sh` runs:

1. `mix test test/js/bytecode_compiler_test.exs`
2. `mix run bench/js_bytecode_compiler_frontier.exs`
3. `mix run bench/js_bytecode_compiler_compat.exs`

All scripts emit structured `METRIC name=value` lines.

## QuickJS/Test Infrastructure
Yes, rely on QuickJS infrastructure here:

- `QuickBEAM.eval/2` is the oracle for each source string.
- `QuickBEAM.JS.BytecodeCompiler.compile/1` must produce a bytecode function.
- `QuickBEAM.VM.Interpreter.eval/4` must match QuickJS.
- `QuickBEAM.VM.Compiler.invoke/2` must match QuickJS.
- `QuickBEAM.JS.BytecodeCompiler.compile_to_binary/1` followed by `QuickBEAM.load_bytecode/2` must match QuickJS.

This gives stronger validation than a parser-only benchmark: it checks semantics and bytecode serialization, not just acceptance. Test262 can be used later by adding curated executable Test262-derived cases to the frontier, but avoid a monolithic Test262 sweep until scope/closures/errors are mature enough to avoid noisy failures.

## Files in Scope
- `lib/quickbeam/js/bytecode_compiler.ex` — public API/orchestration.
- `lib/quickbeam/js/bytecode_compiler/*.ex` — compiler passes, emitter, scope, assembler.
- `lib/quickbeam/vm/bytecode.ex` — neutral bytecode structures.
- `lib/quickbeam/vm/bytecode/writer.ex` — QuickJS binary serialization.
- `lib/quickbeam/vm/opcodes.ex` — opcode metadata boundary only if required.
- `lib/quickbeam/vm/compiler/**` — only for real BEAM-compiler mismatches exposed by compiled bytecode.
- `lib/quickbeam/vm/interpreter/**` — only for real interpreter mismatches exposed by compiled bytecode.
- `test/js/bytecode_compiler_test.exs` — focused regression tests.
- `test/support/js_bytecode_compiler_audit.ex` — stable compatibility audit.
- `bench/js_bytecode_compiler_compat.exs` — stable audit runner.
- `bench/js_bytecode_compiler_frontier.exs` — frontier benchmark for this autoresearch session.
- `autoresearch.sh`, `autoresearch.md`, `autoresearch.checks.sh`, `autoresearch.ideas.md`.

## Off Limits
- Do not modify QuickJS/Test262 inputs to improve the metric.
- Do not couple `QuickBEAM.JS.BytecodeCompiler` to `QuickBEAM.VM.Compiler` internals.
- Do not make the existing VM compiler the frontend compiler.
- Do not default-enable experimental compiler paths globally.
- Do not add external parser/compiler dependencies.
- Do not weaken `mix lint`, ExDNA clone budget, or warning settings.
- Do not special-case exact frontier source strings or names.

## Constraints
- Preserve existing stable audit cleanliness:
  ```text
  js_bytecode_compiler_failures=0
  js_bytecode_compiler_mismatches=0
  js_bytecode_compiler_native_loadable=js_bytecode_compiler_cases
  ```
- Keep emitted binaries QuickJS-loadable.
- Use QuickJS as reference but write idiomatic Elixir.
- Keep the compiler namespace separate:
  ```text
  QuickBEAM.JS.BytecodeCompiler
  ```
- Shared boundaries with existing VM compiler should remain limited to neutral bytecode/opcode/writer infrastructure unless fixing a real VM compiler mismatch.

## Current Frontier Themes
The frontier intentionally covers the next semantic clusters:

- block scope and shadowing;
- `var` vs `let` behavior;
- closures/captured variables;
- nested function declarations;
- switch;
- try/catch/finally/throw;
- constructors and prototype methods;
- builtin method side effects;
- logical assignment;
- delete/in;
- for-in.

When a cluster is fixed, add focused tests and consider moving representative cases into `test/support/js_bytecode_compiler_audit.ex` so they become permanent regression coverage.

## What's Been Tried
- Existing compiler work reached a clean 53-case stable audit before this frontier phase.
- The frontend compiler already supports literals, locals, assignments, compound/update assignments, arithmetic/comparison/unary/logical/sequence expressions, conditionals, `if`, `while`, `do while`, `for`, `break`/`continue`, functions, returns, generic calls, arrays, object literals, shorthand/computed keys, property reads/writes, computed writes, method calls, basic `this`, and QuickJS-loadable binary output.
- Existing BEAM compiler shaped-object stale reads after writes were fixed by invalidating shaped object slot types after compiled `put_field` / `put_array_el`.
