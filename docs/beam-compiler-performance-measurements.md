# BEAM compiler warm-execution measurements

This report separates one-time host-runtime initialization, cold compilation,
and repeated owner-local execution for five bounded lexical/property-loop
workloads. It measures the experimental BEAM compiler against the canonical
interpreter through `QuickBEAM.VM.eval/2` with `isolation: :caller`; native
QuickJS is not part of this comparison.

## Reproduction

```sh
COMPILER_PERF_ITERATIONS=2000 MIX_ENV=bench \
  mix run bench/vm_compiler_perf.exs
```

- Git base: `041fd186`
- Working tree at measurement: modified
- Generated: 2026-07-16T10:32:00Z
- Elixir: 1.20.2
- OTP: 29
- OS: Linux 7.0.0-27-generic
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Iterations per warm tier: 2,000

## Results

The first core-profile evaluation took **44.12 ms**. This one-time runtime
initialization is reported separately and is not folded into the first
workload's compiler time.

| workload | compiled functions | cold compiler eval | warm compiler average | interpreter average | warm speedup |
|---|---:|---:|---:|---:|---:|
| arithmetic loop | 1 | 11.10 ms | 38.25 µs | 312.72 µs | 8.18× |
| branch loop | 1 | 9.72 ms | 50.12 µs | 386.01 µs | 7.70× |
| local arithmetic loop | 1 | 25.86 ms | 93.12 µs | 517.36 µs | 5.56× |
| array sum | 1 | 9.30 ms | 50.40 µs | 91.24 µs | 1.81× |
| object property loop | 1 | 8.50 ms | 48.04 µs | 294.83 µs | 6.14× |

Cold time includes bounded CFG/dataflow analysis, Erlang form compilation,
module installation, lease orchestration, and the first evaluation after the
host template is warm. Warm time includes public VM option handling, root
interpreter dispatch, compiler pool lookup, one generated nested-function
execution, and result completion. It does not hide compiler orchestration by
calling a generated module directly. Both warm tiers seed each evaluation from
the same immutable, profile-specific host template and charge its full logical
allocation. Mutations still remain owner-local through immutable-map
copy-on-write semantics.

## CPU profile

The warm object-property workload was also profiled with `:eprof` for 200
public `eval/2` calls:

```sh
COMPILER_EPROF_PHASE=execution COMPILER_EPROF_ENGINE=compiler \
  COMPILER_EPROF_WORKLOAD=object_property_loop COMPILER_EPROF_ITERATIONS=200 \
  MIX_ENV=bench mix run bench/vm_compiler_eprof.exs
COMPILER_EPROF_PHASE=execution COMPILER_EPROF_ENGINE=interpreter \
  COMPILER_EPROF_WORKLOAD=object_property_loop COMPILER_EPROF_ITERATIONS=200 \
  MIX_ENV=bench mix run bench/vm_compiler_eprof.exs
```

Profiling overhead is substantial, so these are CPU attribution results rather
than latency numbers. The compiler profile recorded 62.56 ms total traced CPU,
including 9.21 ms in generated `block/7` and 3.09 ms in exact scalar step
charging. The interpreter profile recorded 337.01 ms total traced CPU,
including 39.99 ms in `execute_current/2`, 31.39 ms in opcode expansion,
24.03 ms in `run/2`, and 22.70 ms in instruction execution.

A fresh Mix VM can isolate first-profile initialization:

```sh
COMPILER_EPROF_PHASE=initialization COMPILER_EPROF_ENGINE=interpreter \
  MIX_ENV=bench mix run bench/vm_compiler_eprof.exs
```

That single minimal evaluation recorded 22.66 ms traced CPU; 19.71 ms was OTP
module loading (`erts_internal:prepare_loading/2`). Builtin heap construction,
logical accounting, and the persistent-template write were individually below
0.21 ms in that traced run. Initialization and warm generated execution are
therefore reported as separate phases.

The optimized tier keeps verified stack values as generated BEAM expressions,
uses bounded tuple locals, tail-calls generated successor blocks, specializes
numeric operations behind guards, performs non-accessor property reads through
canonical `Properties`, and reconstructs `%QuickBEAM.VM.Frame{}` only at
explicit deoptimization. Fallback clauses still call canonical
`QuickBEAM.VM.Compiler.Runtime` value semantics.

These micro-workload gains do not promote the compiler for release. The pinned
Preact/Vue/Svelte report remains the end-to-end compatibility and performance
gate; object writes, constructors, iterators, Promise operations, and exception
regions still deoptimize to the interpreter. Ordinary calls use explicit
interpreter-owned actions rather than recursive generated execution.
