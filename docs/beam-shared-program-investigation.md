# Bounded shared-program investigation

This investigation profiles the process-isolated BEAM interpreter without
call tracing and addresses the largest measured endpoint cost. It applies only
to immutable, already verified `QuickBEAM.VM.Program` values.

## Non-instrumented profile

The pinned Vue 3.5.39 fixture was sampled on Linux/OTP 29 with:

```sh
ERL_FLAGS='+S 1:1 +JPperf true' perf record -F 997 -e cycles:u -- \
  env MIX_ENV=bench mix run bench/vm_interpreter_perf.exs --mode copied

ERL_FLAGS='+S 1:1 +JPperf true' perf record -F 997 -e cycles:u -- \
  env MIX_ENV=bench mix run bench/vm_interpreter_perf.exs --mode shared
```

`kernel.perf_event_paranoid` was lowered only for the profiling command and
restored afterward. `+JPperf true` supplied BeamAsm symbols to `perf`.

A caller-local render spends its time in interpreter work: map element loads,
map updates, minor collection, opcode dispatch, list append, equality, and hash
map operations. No individual Elixir semantic helper beyond the interpreter
loop owns a large fraction of cycles.

The ordinary isolated path was different. Its largest flat samples were:

| runtime symbol | cycles |
|---|---:|
| `sweep_off_heap` | 16.55% |
| `full_sweep_heaps` | 15.96% |
| `copy_struct_x` | 10.68% |
| `sweep_new_heap` | 7.82% |
| `erts_cleanup_offheap_list` | 5.12% |
| `size_object_x` | 2.54% |

Together these account for about 58.7% of sampled cycles. The immutable decoded
program was captured by the worker closure and copied onto every evaluation
process heap, then traversed again when that process exited. On this fixture the
program has extensive structural sharing but a flat copy size of roughly 7.4
million words. This explains why reducing interpreter map writes did not improve
the old endpoint: process copying and teardown dominated it.

## Design

`QuickBEAM.VM.share_program/1` explicitly places a verified immutable program in
`QuickBEAM.VM.ProgramStore` and returns a small `%QuickBEAM.VM.SharedProgram{}`
handle. Evaluating the handle acquires an owner-monitored lease and fetches the
program from a fixed `:persistent_term` slot before spawning the worker. BeamAsm
retains that literal reference across the spawn instead of copying the graph.
The request process and evaluation worker therefore copy only the handle and
options, not the decoded function graph.

The store is deliberately not an automatic cache:

- sharing is explicit;
- the default capacity is eight and the hard maximum is 32;
- a shared serialized bytecode input is at most 2 MiB;
- slots use fixed integer keys and binary program identities;
- there is no input-derived atom and no implicit eviction;
- concurrent first admission is single-flight;
- every lease has a unique reference and owner monitor;
- owner death returns its lease;
- explicit release waits for active leases and then erases the slot;
- manager restart restores fixed slots without copying programs into its state;
- failed persistent-term installation returns a typed capacity error rather
  than crashing evaluation;
- ordinary `%Program{}` evaluation retains the prior copied-process behavior.

Program identities include the bytecode ABI/version, bytecode digest, source
digest, and filename. JavaScript heaps, globals, cells, jobs, counters, handlers,
and continuations remain evaluation-owner-local. Shared program memory is a
bounded global immutable resource and is intentionally separate from endpoint
process memory and logical JavaScript allocation.

Typical use is:

```elixir
{:ok, program} = QuickBEAM.VM.compile(bundle, filename: "server.js")
{:ok, shared} = QuickBEAM.VM.share_program(program)

Task.async_stream(requests, fn props ->
  QuickBEAM.VM.eval(shared, vars: %{"props" => props})
end)

QuickBEAM.VM.release_program(shared)
```

## Admission cost

Sharing is an initialization operation, not part of the warm-render numbers.
Three fresh-VM Vue admissions took 11.307, 14.298, and 10.995 ms (11.307 ms
median). Admission reserves a slot through the store but installs the persistent
term in the caller, avoiding a giant GenServer message. The program retained
about 310,582 words (approximately 2.37 MiB) in the persistent slot according
to the unsupported ERTS debug size diagnostic,
while its process-copy flat size was 7,370,007 words (approximately 56.23 MiB).
The handle's external encoding was 95 bytes. The store process itself retained
only 3,088 bytes because program terms never enter its mailbox or state.

These are OTP implementation observations, not logical JavaScript memory or a
stable public size API. Applications should share long-lived bundles during
startup and release them during replacement or shutdown, not churn slots per
request.

## Pinned SSR result

The reproducible report is
[`beam-shared-program-measurements.md`](beam-shared-program-measurements.md).
Against the prior copied-program report on the same machine:

| fixture | copied median | shared median | copied endpoint memory | shared endpoint memory |
|---|---:|---:|---:|---:|
| Preact 10.29.7 | 8.22 ms | 7.01 ms | 4.5 MiB | 257.7 KiB |
| Vue 3.5.39 | 49.21 ms | 11.01 ms | 77.15 MiB | 673.3 KiB |
| Svelte 5.56.4 | 15.15 ms | 6.99 ms | 15.61 MiB | 673.3 KiB |

At concurrency eight, Vue improved from 18.1 renders/s with a 204.55 ms median
to 684.7 renders/s with an 11.07 ms median. Exact VM steps, logical memory,
rendered output, limits, cancellation, and native parity are unchanged.

The published
[`beam-shared-program-scheduler-measurements.md`](beam-shared-program-scheduler-measurements.md)
report measured a 4.91 ms Vue median without the SSR report's fixed 5 ms handler
delay, a 2.04 ms maximum ticker gap against the 75 ms bound, and a 51.0 ms
timeout p95 against the 60 ms bound.

After sharing, the endpoint `perf` profile returns to interpreter work. Program
copy helpers fall below 0.5% individually; minor collection is 8.48%, map element
loads are the largest execution primitive, and no new semantic representation
is justified by the remaining profile.
