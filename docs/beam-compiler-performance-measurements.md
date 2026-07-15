# BEAM compiler warm-execution measurements

This report separates cold compilation from repeated owner-local execution for
three bounded lexical-loop workloads. It measures the experimental BEAM compiler
against the canonical interpreter through `QuickBEAM.VM.eval/2` with
`isolation: :caller`; native QuickJS is not part of this comparison.

## Reproduction

```sh
COMPILER_PERF_ITERATIONS=2000 MIX_ENV=bench \
  mix run bench/vm_compiler_perf.exs
```

- Git base: `85d7a677`
- Working tree at measurement: modified
- Generated: 2026-07-15T23:01:55Z
- Elixir: 1.20.2
- OTP: 29
- OS: Linux 7.0.0-27-generic
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Iterations per warm tier: 2,000

## Results

| workload | compiled functions | cold compiler eval | warm compiler average | interpreter average | warm speedup |
|---|---:|---:|---:|---:|---:|
| arithmetic loop | 1 | 42.61 ms | 300.45 µs | 515.71 µs | 1.72× |
| branch loop | 1 | 9.26 ms | 304.48 µs | 598.69 µs | 1.97× |
| local arithmetic loop | 1 | 26.76 ms | 317.08 µs | 732.01 µs | 2.31× |

Cold time includes bounded CFG/dataflow analysis, Erlang form compilation,
module installation, lease orchestration, and the first evaluation. Warm time
includes public VM option handling, root interpreter dispatch, compiler pool
lookup, one generated nested-function execution, and result completion. It does
not hide compiler orchestration by calling a generated module directly.

The optimized tier keeps verified stack values as generated BEAM expressions,
uses bounded tuple locals, tail-calls generated successor blocks, specializes
numeric operations behind guards, and reconstructs `%QuickBEAM.VM.Frame{}` only
at explicit deoptimization. Fallback clauses still call canonical
`QuickBEAM.VM.Compiler.Runtime` value semantics.

These micro-workload gains do not promote the compiler for release. The pinned
Preact/Vue/Svelte report remains the end-to-end compatibility and performance
gate; unsupported object, call, iterator, Promise, and exception operations
still deoptimize to the interpreter.
