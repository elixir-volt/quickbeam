# BEAM object-memory investigation

This investigation studies QuickBEAM's JavaScript object heap against Erlang/OTP
29 and current OTP `master`. It is an implementation-specific optimization
record, not a general JavaScript performance claim.

## What OTP actually optimizes

BeamAsm performs load-time instruction specialization but deliberately does very
little cross-instruction optimization. The Erlang compiler's SSA, type, alias,
and liveness passes therefore determine which native fast paths are reachable.
The relevant sources are:

- [`BeamAsm.md`](https://github.com/erlang/otp/blob/master/erts/emulator/internal_doc/BeamAsm.md)
- [`jit/x86/instr_map.cpp`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/jit/x86/instr_map.cpp)
- [`jit/x86/instr_common.cpp`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/jit/x86/instr_common.cpp)
- [`beam_common.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/beam_common.c)
- [`erl_map.c`](https://github.com/erlang/otp/blob/master/erts/emulator/beam/erl_map.c)

Small map literals with literal keys are excellent construction targets. The x86
JIT emits their headers and values directly at `HTOP`, shares the literal key
tuple, and can move adjacent values with SIMD. Tuple construction is similarly
direct. In contrast, associative and exact map updates generally enter shared C
runtime fragments. Flatmaps contain at most 32 entries; inserting a key copies
keys and values, while exact updates can retain the old key tuple but still copy
the value vector. Larger maps are persistent HAMTs.

OTP 26 and later can combine fixed-size tuple updates into `update_record`.
Recent compiler alias analysis can mark a dead, unique tuple `inplace`, allowing
the JIT to overwrite it when doing so cannot create an old-to-young pointer.
This is useful for fixed internal state authored as Erlang records. It does not
make dynamic JavaScript property dictionaries mutable. OTP 29 native records are
experimental and require atom field names, so they are not suitable for
user-derived JavaScript keys.

Inspecting assembly is therefore useful, but only in a measured loop:

1. inspect BEAM shape with `erlc -S` or `:beam_disasm.file/1`;
2. inspect the matching BeamAsm emitter and runtime helper;
3. use `+JPperf true`, `perf`, reductions, GC observations, and `:eprof` on the
   real workload.

`erts_debug:disassemble/1` returns `false` on BeamAsm because that disassembler
is compiled only for the non-JIT emulator.

### QuickBEAM's emitted BEAM

`:beam_disasm.file/1` confirms the shape of compact writes rather than assuming
source-level syntax is cheap. `store_default_array_index/6` and the common
`put_default_property/3` path emit a `test_heap 2` plus `put_tuple2` for
`{value}`, then call `maps:put/3` for the property dictionary. The array
`%Object{}` update is one `put_map_exact` carrying both `:properties` and
`:length`; the ordinary-object path updates `:properties`. The outer heap still
requires another `maps:put/3`, followed by a final exact `%Execution{}` map
update. A new property calls `Memory.charge_property/3`; replacement skips that
charge before allocating the compact tuple.

The full descriptor path constructs a `%Property{}` flatmap before performing
the same persistent dictionary, object, outer-heap, and execution updates. The
assembly therefore predicts exactly the measured result: compact descriptors
remove substantial per-element retained allocation, but they do not remove the
persistent update cascade. Hidden classes and a different owner-local heap
layout are required to address that remaining CPU cost.

## Allocation pathology found

The VM stored every array index twice:

- as an integer key in `Object.properties`; and
- in `Object.property_order` using `property_order ++ [key]`.

ECMAScript integer keys are already enumerated from the property dictionary and
sorted numerically. The insertion-order list is consulted only for non-integer
keys. Sequential array growth was therefore performing a useless quadratic list
append and retaining every index twice.

The first fix removes integer keys from `property_order` and bulk-constructs
literal arrays in one heap update. Exact VM steps and logical memory accounting
are unchanged.

A second representation improvement encodes every default data descriptor
directly in the existing property map as the one-tuple `{value}`. Accessors and
data properties with non-default descriptor flags remain full
`%QuickBEAM.VM.Property{}` values. Reflection expands the compact form only at
the canonical descriptor boundary. Common writes avoid constructing a transient
full descriptor, and property definition reuses its validated candidate rather
than building it twice. This keeps one OTP map, one lookup path, and canonical
descriptor behavior. No input-derived atoms, ETS table, process dictionary, or
native mutable state is introduced.

## Measurements

A synthetic retained workload creating 5,000 outer-array entries and 10,000
ordinary objects showed why the first fix matters:

- wall observation: 110.35 ms to 84.22 ms;
- reductions: 8.22 million to 7.83 million;
- retained insertion-order cells: 40,352 to 35,352.

The dedicated 20,000-element isolated array fixture compares the pre-compaction
layout with the compact default descriptor:

| layout | wall median | reductions median | endpoint process memory | steps | logical memory |
|---|---:|---:|---:|---:|---:|
| full descriptor per element | 74.87 ms | 9,803,575 | 7.28 MiB | 280,022 | 1.95 MiB |
| compact default descriptor | 72.92 ms | 9,655,746 | 2.78 MiB | 280,022 | 1.95 MiB |

The compact array representation reduces endpoint process memory by about 62%,
reductions by 1.5%, and observed wall time by 2.6% in that paired run.

A second paired fixture retains 5,000 ordinary three-property objects:

| layout | wall median | reductions median | endpoint process memory | retained VM heap | steps | logical memory |
|---|---:|---:|---:|---:|---:|---:|
| full ordinary descriptors | 45.50 ms | 5,011,812 | 9.13 MiB | 3.30 MiB | 130,022 | 5.14 MiB |
| compact ordinary descriptors | 44.97 ms | 4,904,137 | 7.28 MiB | 2.27 MiB | 130,022 | 5.14 MiB |

This lowers the shared retained VM heap by 31%, reductions by 2.1%, and observed
wall time by 1.2%. Endpoint process memory is less stable because it reports
allocated BEAM heap classes rather than only live terms. The reproducible report
therefore includes both endpoint memory and diagnostic `:erts_debug.size/1`
retained bytes:
[`beam-object-memory-measurements.md`](beam-object-memory-measurements.md).

Three paired five-render Vue `:eprof` repetitions had median totals of 466.44 ms
before ordinary-object compaction and 462.88 ms after it. The improvement is
small but, together with lower deterministic reductions, rules out hiding a CPU
regression behind the retained-memory win.

## Rejected representations

OTP's `array` module is a mature persistent 16-way tuple tree and is excellent
when its API amortizes surrounding work. In a standalone 20,000-entry build it
used 22,705 words and took about 0.60 ms, versus 293,811 words and 4.98 ms for a
map of full descriptors. However, placing `:array` behind every canonical
JavaScript property operation added Erlang call, wrapper, and tree-update costs.
Pinned SSR reductions rose materially and endpoint heap classes increased. The
representation was rejected.

A separate raw element map plus exceptional descriptor map also reduced retained
terms but required two lookup/update paths and enlarged array objects. It
regressed SSR reductions and was rejected. Encoding compact values in the
existing map retained the memory benefit without a second persistent structure.

The evaluation's outer object heap has dense, monotonic integer IDs, so OTP
`:array` was also tested there rather than as a JavaScript property store. The
full VM and pinned Test262 gates passed. However, the 5,000-object fixture reduced
retained heap size only from 2.32 MiB to 2.22 MiB while increasing reductions by
8.1%; the 20,000-element fixture had negligible retained improvement and 4.4%
more reductions. Three paired Vue `:eprof` repetitions had median CPU totals of
567.10 ms for the persistent map and 607.12 ms for `:array`, a 7.1% regression.
The outer persistent map remains the better fit.

Private ETS was not selected. ETS would copy inserted and fetched terms, lose
literal/subterm sharing, move memory outside the evaluation process's
`max_heap_size`, and require separate accounting and cleanup. It remains a
candidate only if a future measured overlay beats the persistent one-map design.

## Next deep optimization: shapes

Ordinary objects no longer retain a descriptor struct for default fields, but
each new field still performs a property-map update, an object-struct update,
and an outer heap-map update. Non-default definitions also construct descriptor
maps. The next high-leverage design is a bounded owner-local hidden-class fast
path:

- integer shape IDs, never dynamic atoms;
- one shape record containing ordered keys, default descriptors, and key-to-slot
  indices;
- one compact values tuple per object;
- cached `{shape, key, flags}` transitions;
- dictionary fallback for deletes, accessors, non-default descriptors, and
  pathological dynamic keys;
- bulk object-literal construction into its final shape;
- optional owner-local string-key interning to immediate integer IDs, keeping
  non-negative integers reserved for ECMAScript array indices.

This design should be prototyped against exact result/step/memory differentials
before changing the canonical heap. Fixed metadata helpers may be authored as
Erlang records to expose OTP's `update_record` optimization, but native records
remain too experimental for the runtime contract.

## Process heap sizing

OTP's efficiency guide explicitly recommends a larger `min_heap_size` for
short-lived compute processes. QuickBEAM's isolated evaluation owner is a good
match because process termination bulk-reclaims the heap. A controlled Vue probe
found a best inner-evaluation median near a 1 MiB initial heap, but repeated
system-level SSR runs were too noisy and small fixtures retained roughly an
extra MiB heap class. No default was changed. A future adaptive policy must be a
separate, paired benchmark with concurrency, scheduler, peak-memory, binary
retention, and low-memory-limit gates.
