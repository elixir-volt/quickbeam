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

- Git base: `bc1aaf50`
- Working tree at measurement: modified
- Generated: 2026-07-16T09:40:00Z
- Elixir: 1.20.2
- OTP: 29
- OS: Linux 7.0.0-27-generic
- CPU: AMD Ryzen 9 9950X 16-Core Processor
- Iterations per warm tier: 2,000

## Results

The first core-profile evaluation took **50.62 ms**. This one-time runtime
initialization is reported separately and is not folded into the first
workload's compiler time.

| workload | compiled functions | cold compiler eval | warm compiler average | interpreter average | warm speedup |
|---|---:|---:|---:|---:|---:|
| arithmetic loop | 1 | 15.95 ms | 38.31 µs | 315.17 µs | 8.23× |
| branch loop | 1 | 11.08 ms | 52.40 µs | 400.73 µs | 7.65× |
| local arithmetic loop | 1 | 25.65 ms | 91.74 µs | 522.34 µs | 5.69× |
| array sum | 1 | 12.74 ms | 54.11 µs | 92.58 µs | 1.71× |
| object property loop | 1 | 10.77 ms | 55.91 µs | 294.28 µs | 5.26× |

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
than latency numbers. The compiler profile recorded 76.82 ms total traced CPU,
including 12.05 ms in generated `block/7` and 7.07 ms in exact scalar step
charging. The interpreter profile recorded 386.12 ms total traced CPU,
including 40.30 ms in `execute_current_opcode/4`, 34.83 ms in opcode expansion,
26.68 ms in `run/2`, and 23.63 ms in instruction execution. Property reads use
separate preflight blocks so accessor/error deoptimization does not pre-charge
or duplicate the instruction; this correctness boundary explains part of the
property-heavy overhead.

A fresh Mix VM can isolate first-profile initialization:

```sh
COMPILER_EPROF_PHASE=initialization COMPILER_EPROF_ENGINE=interpreter \
  MIX_ENV=bench mix run bench/vm_compiler_eprof.exs
```

That single minimal evaluation recorded 19.67 ms traced CPU; 17.05 ms was OTP
module loading (`erts_internal:prepare_loading/2`). Builtin heap construction,
logical accounting, and the persistent-template write were individually below
0.21 ms in that traced run. Initialization and warm generated execution are
therefore reported as separate phases.

The pinned Vue fixture can be profiled separately from micro-workloads:

```sh
COMPILER_SSR_EPROF_ITERATIONS=3 COMPILER_SSR_EPROF_PROFILE=interpreter \
  MIX_ENV=bench mix run bench/vm_compiler_ssr_eprof.exs
COMPILER_SSR_EPROF_ITERATIONS=3 COMPILER_SSR_EPROF_PROFILE=pure_v1 \
  MIX_ENV=bench mix run bench/vm_compiler_ssr_eprof.exs
COMPILER_SSR_EPROF_ITERATIONS=3 COMPILER_SSR_EPROF_PROFILE=scalar_v1 \
  MIX_ENV=bench mix run bench/vm_compiler_ssr_eprof.exs
```

The three traced runs recorded 281.72 ms for the interpreter, 300.34 ms for
`:pure_v1`, and 292.91 ms for `:scalar_v1`. The compiler runs spent about
11.8 ms across three renders in `term_to_binary/2`; artifact identities now
hash the exact program namespace once per evaluation and omit repeated atom
tables from per-function payloads. These profiles also motivated fixed OTP
`:counters` at the measurement boundary: Vue currently executes only 0.4% of
steps through `:pure_v1` and 1.1% through `:scalar_v1`, so bounded coverage—not
scalar primitive speed—is the remaining SSR bottleneck.

The optimized tier keeps verified stack values as generated BEAM expressions,
uses bounded tuple locals, tail-calls generated successor blocks, specializes
numeric operations behind guards, performs non-accessor property reads through
canonical `Properties`, threads canonical global reads/writes through owner-local
execution state, and reconstructs `%QuickBEAM.VM.Frame{}` only at
explicit deoptimization. Fallback clauses still call canonical
`QuickBEAM.VM.Compiler.Runtime` value semantics.

These micro-workload gains do not promote the compiler for release. The pinned
Preact/Vue/Svelte report remains the end-to-end compatibility and performance
gate; object writes, constructors, iterators, Promise operations, and exception
regions still deoptimize to the interpreter. Ordinary calls use explicit
interpreter-owned actions rather than recursive generated execution.
