# BEAM interpreter hotspot investigation

This report attributes one warm render of the pinned Vue 3.5.39 fixture after
the compact-object work. It records rejected experiments as well as retained
conclusions because reductions and instrumented profiler time did not reliably
predict endpoint latency.

## Method

The caller graph is reproducible with:

```sh
VM_INTERPRETER_FPROF_OUTPUT=/tmp/vue.fprof \
  MIX_ENV=bench mix run bench/vm_interpreter_fprof.exs
```

The runner warms the interpreter, then profiles one caller-isolated render with
`:fprof`. Candidate changes were evaluated separately with paired, alternating
runs of the process-isolated Vue fixture. Each controlled run used 200 samples
and preserved output, 11,957 VM steps, and 1,015,684 bytes of logical memory.
Single-scheduler runs used `ERL_FLAGS='+S 1:1'` and CPU affinity. Default-scheduler
checks were also made for the constant-pool experiment.

`:fprof` is useful here for exact call counts and caller attribution. Its elapsed
and own-time columns are not release measurements: tracing magnifies functions
that recurse or make many calls. Endpoint wall time remains the acceptance gate.

## Persistent-map attribution

One Vue render made 5,600 `maps:put/3` calls. The caller graph separates them as
follows:

| category | calls | share |
|---|---:|---:|
| outer object heap updates | 3,126 | 55.8% |
| object property dictionaries | 1,729 | 30.9% |
| globals and closure cells | 730 | 13.0% |
| promises and other state | 15 | 0.3% |

The outer-heap total consists of 1,001 object insertions, 983 writes after
property definition, 741 writes after ordinary property assignment, 364 array
index writes, 26 generic object updates, nine descriptor writes, and two
prototype writes. Property dictionaries account for 1,166 compact default-data
writes and 563 exceptional/full-descriptor writes.

This rules out an unmeasured assumption that descriptor maps dominate the
remaining churn. The largest population is the sequential-ID outer heap, whose
OTP `:array` replacement was already rejected: it slightly reduced retained
heap but increased reductions by 8.1% and regressed Vue `:eprof` CPU by 7.1%.
The accepted persistent map remains the better release representation.

The same render made 5,491 `maps:find/2` calls, including 4,311 direct object
fetches and 1,073 prototype/property-depth lookups. These are canonical semantic
operations rather than duplicate descriptor lookups.

## Constant-pool experiment

Caller tracing initially appeared to identify a larger problem than map churn:
567 nested-function lookups through list-backed constant pools produced about
114,000 recursive list-drop calls. Converting every function constant pool to a
tuple removed that recursion and reduced traced calls from roughly 451,000 to
336,000.

The isolated endpoint results did not support promotion:

- reductions fell from about 702,000–705,000 to 584,000–587,000;
- endpoint process memory fell from 97,079,584 to 80,899,872 bytes;
- the controlled single-scheduler wall median increased from 46.69 ms to
  49.45 ms in the representative paired run;
- repeated default-scheduler checks were neutral to slower rather than showing
  a stable latency gain.

A full OTP `:array` constant pool sometimes improved median wall time, but raised
endpoint process memory to 102,676,424 bytes and had unstable tail behavior. A
32-entry hybrid retained the baseline heap class but consistently regressed the
controlled median by about 7%. A separate nested-function index duplicated the
recursive function graph during isolated-process copying and exceeded the
worker resource bound.

The list constant pool is therefore retained. The result also demonstrates why
recursive call count, reductions, and process heap class cannot substitute for
the pinned endpoint gate.

## Smaller rejected fast paths

Three local changes reduced profiler work or BEAM reductions but regressed
paired wall time:

- replacing the opcode metadata map with a dense tuple reduced reductions by
  about 3%, while the median increased by about 7%;
- replacing short-opcode alias map lookups with generated function clauses
  reduced reductions by about 10%, while the median increased by about 6%;
- bypassing `%Property{}` construction for 425 ordinary default definitions
  left reductions effectively unchanged and increased the median by about 7%.

None is retained. Small map lookups and the current compact-property path are
already effective under BeamAsm; source-level operation counts did not expose a
better endpoint implementation.

## Decision

No runtime representation or fast-path change from this phase is promoted.
Release defaults remain:

- list-backed immutable constant pools;
- compact `{value}` default descriptors in one property map;
- persistent maps for the owner-local outer heap, globals, and cells;
- canonical incremental property semantics;
- interpreter-first execution with compiler regions disabled.

Further work should begin from a dynamically larger semantic population than
the 425 default-definition shortcut or 567 function-constant lookups. It must
measure pinned Preact, Vue, and Svelte wall time, reductions, endpoint process
memory, scheduler behavior, exact steps, and logical memory before changing the
release representation.
