# Benchmarks

Benchmarks are grouped by purpose and follow the same conventions:

- scripts live directly under `bench/*.exs`
- shared helpers live under `bench/support/*.exs`
- tunables come from environment variables
- machine-readable values are printed as `METRIC name=value`
- Benchee scripts accept `BENCH_WARMUP`, `BENCH_TIME`, and `BENCH_MEMORY_TIME`

Most scripts run with the normal app environment:

```sh
mix run bench/<script>.exs
```

QuickJSEx comparison scripts need the `:bench` Mix environment because QuickJSEx
and Benchee are bench-only dependencies:

```sh
MIX_ENV=bench mix run bench/eval_roundtrip.exs
```

For release-style measurements, compile first with fast Zig output:

```sh
ZIGLER_RELEASE_MODE=fast MIX_ENV=bench mix compile --force
```

## Runtime bridge benchmarks

These compare QuickBEAM's NIF bridge with QuickJSEx:

```sh
MIX_ENV=bench mix run bench/eval_roundtrip.exs
MIX_ENV=bench mix run bench/call_with_data.exs
MIX_ENV=bench mix run bench/beam_call.exs
MIX_ENV=bench mix run bench/shared_context.exs
MIX_ENV=bench mix run bench/startup.exs
MIX_ENV=bench mix run bench/concurrent.exs
```

## Parser benchmarks and audits

```sh
mix run bench/js_parser_compat.exs
mix run bench/js_parser_perf.exs
mix run bench/js_parser_quickjs_audit.exs
```

## JS compiler audits

These cover the separate frontend compiler that lowers `QuickBEAM.JS.Parser` AST
to QuickBEAM VM instructions:

```sh
mix run bench/js_compiler_compat.exs
```

Useful environment variables:

- `TEST262_GLOB` — file glob, default `test/test262/test/**/*.js`
- `TEST262_SAMPLE_OFFSET` — offset into the sorted file list
- `TEST262_SAMPLE_LIMIT` — number of files to inspect
- `TEST262_ERROR_LIMIT` — number of parser errors printed by the compat script
- `PARSER_PERF_REPEAT` — repeated perf runs; the best run is reported
- `AUDIT_OFFSET`, `AUDIT_LIMIT` — QuickJS acceptance audit window

## VM compiler audits

```sh
mix run bench/vm_compiler_compat.exs
mix run bench/vm_compiler_corpus.exs
mix run bench/vm_compiler_opcode_coverage.exs
mix run bench/vm_compiler_semantic_gaps.exs
MIX_ENV=test mix run bench/vm_compiler_test262.exs
mix run bench/vm_compiler_perf.exs
```

Useful environment variables:

- `COMPILER_PERF_ITERATIONS` — invoke iterations per compiler perf workload
- `TEST262_CATEGORY` — comma-separated category filter for compiler Test262 audit
- `TEST262_LIMIT` — max compiler Test262 cases
- `TEST262_CASE_TIMEOUT` — per-case timeout in milliseconds

## Preact VM workload

```sh
MIX_ENV=bench mix run bench/preact_vm.exs
mix run bench/preact_vm_profile.exs
```

`bench/preact_vm.exs` bundles `bench/assets/preact_ssr.js` with Bun and compares
native QuickJS, `QuickBEAM.VM.Interpreter.invoke/3`, and
`QuickBEAM.VM.Compiler.invoke/2` on a real Preact component tree workload.

`bench/preact_vm_profile.exs` writes diagnostic artifacts to `/tmp/`:

- `preact_vm_render_app_quickjs.txt`
- `preact_vm_render_app_opcodes.txt`
- `preact_vm_beam_disasm.txt`
- `preact_vm_profile_summary.txt` when `:eprof` is unavailable locally

## Autoresearch entrypoint

`autoresearch.sh` dispatches to the parser/compiler benchmark scripts through
`PARSER_BENCH` and appends common parser test metrics. Supported values:

- `compat`
- `perf`
- `quickjs_audit`
- `quickjs_audit_exunit`
- `quickjs_audit_sweep`
- `vm_compiler_audit`
- `vm_compiler_corpus`
- `vm_compiler_opcodes`
- `vm_compiler_perf`
- `vm_compiler_semantics`
- `vm_compiler_test262`
