# Benchmarks

Comparing QuickBEAM (Zig NIF, native term bridge) against QuickJSEx 0.3.1
(Rust/Rustler NIF, JSON serialization).

## Running

Build with ReleaseFast optimization (matches QuickJSEx's precompiled release build):

```sh
ZIGLER_RELEASE_MODE=fast MIX_ENV=bench mix compile --force
```

Run individual benchmarks:

```sh
MIX_ENV=bench mix run bench/eval_roundtrip.exs
MIX_ENV=bench mix run bench/call_with_data.exs
MIX_ENV=bench mix run bench/beam_call.exs
MIX_ENV=bench mix run bench/startup.exs
MIX_ENV=bench mix run bench/concurrent.exs

# Reproduce the pinned BEAM VM SSR report
MIX_ENV=bench mix run bench/vm_ssr.exs \
  --output docs/beam-ssr-measurements.md

# Reproduce the retained array/object-memory measurement
MIX_ENV=bench mix run bench/vm_object_memory.exs \
  --output docs/beam-object-memory-measurements.md

# Reproduce runtime-initialization, cold-compilation, and warm loop measurements
COMPILER_PERF_ITERATIONS=2000 MIX_ENV=bench \
  mix run bench/vm_compiler_perf.exs

# Profile warm generated execution or one-time host-template initialization
COMPILER_EPROF_PHASE=execution COMPILER_EPROF_ENGINE=compiler \
  COMPILER_EPROF_WORKLOAD=object_property_loop COMPILER_EPROF_ITERATIONS=200 \
  MIX_ENV=bench mix run bench/vm_compiler_eprof.exs
COMPILER_EPROF_PHASE=initialization COMPILER_EPROF_ENGINE=interpreter \
  COMPILER_EPROF_WORKLOAD=object_property_loop MIX_ENV=bench \
  mix run bench/vm_compiler_eprof.exs

# Attribute interpreter calls in one warm pinned Vue render
VM_INTERPRETER_FPROF_OUTPUT=/tmp/vue.fprof \
  MIX_ENV=bench mix run bench/vm_interpreter_fprof.exs

# Attribute CPU in the pinned Vue fixture
COMPILER_SSR_EPROF_PROFILE=scalar_v1 COMPILER_SSR_EPROF_ITERATIONS=3 \
  MIX_ENV=bench mix run bench/vm_compiler_ssr_eprof.exs
COMPILER_SSR_EPROF_PROFILE=scalar_v1 COMPILER_SSR_EPROF_REGIONS=true \
  COMPILER_SSR_EPROF_ITERATIONS=3 MIX_ENV=bench \
  mix run bench/vm_compiler_ssr_eprof.exs

# Reproduce the release-quarantined compiler SSR reports
MIX_ENV=bench mix run bench/vm_ssr.exs \
  --engine compiler --output docs/beam-compiler-ssr-measurements.md
MIX_ENV=bench mix run bench/vm_ssr.exs \
  --engine compiler --compiler-profile scalar_v1 \
  --output docs/beam-compiler-scalar-ssr-measurements.md

# Reproduce bounded-region opportunity and rejected executor measurements
MIX_ENV=bench mix run bench/vm_compiler_region_probe.exs \
  --output docs/beam-compiler-region-probe.md
MIX_ENV=bench mix run bench/vm_compiler_region_hotspots.exs \
  --output docs/beam-compiler-region-hotspots.md
MIX_ENV=bench mix run bench/vm_ssr.exs \
  --engine compiler --compiler-profile scalar_v1 --compiler-regions \
  --output docs/beam-compiler-region-ssr-measurements.md

# Reproduce the interpreter single-scheduler fairness/timeout probe
ERL_FLAGS='+S 1:1' MIX_ENV=bench mix run bench/vm_scheduler_probe.exs \
  --output docs/beam-scheduler-measurements.md

# Reproduce the release-quarantined compiler-tier probe
ERL_FLAGS='+S 1:1' MIX_ENV=bench mix run bench/vm_scheduler_probe.exs \
  --engine compiler --output docs/beam-compiler-scheduler-measurements.md
ERL_FLAGS='+S 1:1' MIX_ENV=bench mix run bench/vm_scheduler_probe.exs \
  --engine compiler --compiler-profile scalar_v1 \
  --output docs/beam-compiler-scalar-scheduler-measurements.md
```

The compiler performance runner reports one-time core-profile initialization
separately before measuring cold compilation and warm execution. The eprof
runner accepts `COMPILER_EPROF_PHASE=execution|initialization`; initialization
profiles exactly one first evaluation in a fresh Mix VM, while execution warms
the profile template and generated artifact before collecting samples.

The SSR and scheduler runners accept `--compiler-profile pure_v1|scalar_v1`.
The SSR runner also accepts `--engine interpreter|compiler`, the quarantined
`--compiler-regions` experiment, `--samples`, `--warmup`, and a comma-separated
`--concurrency` list. It reports deterministic
VM steps and logical allocation, fixed compiler coverage counters,
endpoint BEAM process observations, sequential latency, concurrent throughput,
and timeout/cancellation behavior for the pinned Preact, Vue, and Svelte
fixtures. Published results are in
[`docs/beam-ssr-measurements.md`](../docs/beam-ssr-measurements.md),
[`docs/beam-object-memory-investigation.md`](../docs/beam-object-memory-investigation.md),
[`docs/beam-object-memory-measurements.md`](../docs/beam-object-memory-measurements.md),
[`docs/beam-object-shape-investigation.md`](../docs/beam-object-shape-investigation.md),
[`docs/beam-object-literal-investigation.md`](../docs/beam-object-literal-investigation.md),
[`docs/beam-interpreter-hotspot-investigation.md`](../docs/beam-interpreter-hotspot-investigation.md),
[`docs/beam-compiler-performance-measurements.md`](../docs/beam-compiler-performance-measurements.md),
[`docs/beam-compiler-ssr-measurements.md`](../docs/beam-compiler-ssr-measurements.md),
[`docs/beam-compiler-scalar-ssr-measurements.md`](../docs/beam-compiler-scalar-ssr-measurements.md),
[`docs/beam-compiler-region-investigation.md`](../docs/beam-compiler-region-investigation.md),
[`docs/beam-compiler-region-ssr-measurements.md`](../docs/beam-compiler-region-ssr-measurements.md),
[`docs/beam-scheduler-measurements.md`](../docs/beam-scheduler-measurements.md),
[`docs/beam-compiler-scheduler-measurements.md`](../docs/beam-compiler-scheduler-measurements.md),
and
[`docs/beam-compiler-scalar-scheduler-measurements.md`](../docs/beam-compiler-scalar-scheduler-measurements.md).

## Results

Apple M1 Pro, Elixir 1.18.4, OTP 27, Zig 0.15.2 (ReleaseFast).

### 1. Eval round-trip

Minimal eval (`1 + 2`) — measures bridge overhead, not JS speed.

| | ips | median |
|---|---|---|
| QuickBEAM | 83.1K | 11.5 μs |
| QuickJSEx | 83.3K | 11.2 μs |

**Parity.** Both hit the same GenServer + dirty IO NIF floor.

### 2. Function call with data

Call a JS function with Elixir data, get structured result back.
QuickBEAM uses direct JSValue↔BEAM term conversion; QuickJSEx uses JSON.

| | ips | median | vs QuickJSEx |
|---|---|---|---|
| **Small map** (6 keys) | 62.7K | 13.5 μs | **2.2x faster** |
| **Medium map** (20 keys, nested) | 16.7K | 51.9 μs | **2.4x faster** |
| **Large array** (100 objects × 13 fields) | 4.6K | 196.6 μs | **4.0x faster** |

Advantage grows with data size — JSON serialization cost is O(n), native conversion has lower constant factors.

### 3. beam.callSync (JS → BEAM)

JS calls an Elixir handler and gets a result back. QuickJSEx cannot do this.

| | ips | median | overhead vs pure JS |
|---|---|---|---|
| Pure JS compute | 89.8K | 10.8 μs | — |
| beam.callSync echo | 57.0K | 16.2 μs | +5.4 μs |
| beam.callSync compute | 57.8K | 16.0 μs | +5.2 μs |

~5 μs overhead per BEAM round-trip. The handler runs an Elixir function and returns the result — fast enough for tight loops.

### 4. Runtime startup

| | ips | median |
|---|---|---|
| QuickBEAM start+stop | 1.55K | 591 μs |
| QuickJSEx start+stop | 1.47K | 631 μs |
| QuickBEAM start+eval+stop | 1.65K | 597 μs |
| QuickJSEx start+eval+stop | 1.47K | 638 μs |

**~600 μs per runtime.** Fast enough for per-request isolation if needed.

### 5. Shared context — preloaded function calls

The typical pattern: load JS once, call functions repeatedly. Same context persists across calls.

| | QuickBEAM | QuickJSEx | Speedup |
|---|---|---|---|
| `call(fn)` — no args | 12.0 μs | 31.2 μs | **2.6x** |
| `call(fn, scalar)` | 11.1 μs | 29.6 μs | **2.6x** |
| `call(fn, 50 objects)` | 97.0 μs | 301.8 μs | **3.1x** |

Even with zero data, QuickBEAM's `call` path is 2.6x faster — QuickJSEx
JSON-encodes the function name and args.

### 6. Concurrent throughput

N runtimes each computing `fib(25)` in parallel via Task.async.

| Runtimes | QuickBEAM ips | QuickJSEx ips | Speedup |
|---|---|---|---|
| 1 | 290 | 211 | **1.38x** |
| 2 | 274 | 200 | **1.37x** |
| 4 | 178 | 130 | **1.37x** |
| 8 | 141 | 106 | **1.34x** |
| 10 | 122 | 91 | **1.35x** |

Consistent 1.35x advantage. Both scale linearly — each runtime runs on its own dirty IO scheduler thread.
