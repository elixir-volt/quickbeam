# Bounded BEAM compiler contract

Status: implemented experimental gate for the optional compiler. The tier remains
release-quarantined, and no prototype compiler runtime is approved for copying.

## Scope

The compiler is an optimization tier for an already verified
`QuickBEAM.VM.Program`. It is not a JavaScript parser, a third execution engine,
or a native fallback. QuickJS still produces bytecode, the current decoder and
verifier remain authoritative, and all mutable JavaScript state remains owned by
one evaluation process.

The first extraction slice is intentionally narrow: verified basic blocks
containing literals, stack movement, local reads/writes, primitive value
operations, and terminal branches. Lowering first builds a bounded immutable
block plan, then emits fixed-name generated forms. The generic path uses
`run/3` and `block/4` with bounded canonical runtime block calls. Eligible scalar
loops use `run/3` and `block/7`, retain stack values as BEAM expressions, carry
locals as bounded tuples, and rebuild canonical frames only at deoptimization.
The conservative `:pure_v1` profile remains the default. The explicitly selected
`:scalar_v1` profile additionally lets ordinary scalar `call` and `call_method`
instructions return canonical invocation actions and lets non-accessor property
reads continue in generated code. Accessors deopt before invocation.
Constructors, iterators, exceptions,
Promise operations, host calls, and `await` still deopt before their instruction
until their resumable compiler ABI exists.

The root frame always receives an eligibility attempt. Nested frames are
selected by a 32-operation entry prefix on the generic path; scalar-eligible
functions may instead qualify by total lowered size or a verified backward CFG
edge. Owner-local compile or skip decisions are cached for at most 256
function IDs per evaluation. The module pool also keeps at most 256 binary-keyed
negative decisions, avoiding repeated warm lowering without creating atoms.

Scalar lowering is deliberately narrower: at most 64 lowered operations, 16
blocks, 32 operations per block, eight arguments, eight locals, and stack depth
64. Locals captured by nested functions are excluded. Lexical checked-local
reads require a successful initialization dataflow proof; otherwise the generic
before-instruction deoptimization path remains authoritative.

## Non-negotiable invariants

1. Compiling unbounded user input never creates an unbounded number of atoms.
2. Generated code never owns a heap, globals, cells, Promise state, jobs, or
   handler tasks. It receives and returns canonical `%Frame{}` and
   `%Execution{}` values.
3. Generated code calls one versioned compiler runtime ABI and never calls heap
   internals. Allowlisted BEAM primitives may specialize proven or guarded
   primitive values; every guard miss calls the canonical runtime semantics.
4. Every transition to the interpreter is an explicit, validated deoptimization
   at a verified instruction boundary.
5. A timeout, memory failure, step failure, throw, or suspension has the same
   external result and owner cleanup as interpreter execution.
6. No compiler failure invokes native QuickJS. An explicitly selected compiler
   mode returns a typed error or deoptimization result.
7. Loaded code is reused only while protected by a live pool lease. Stale
   module/function tuples are never valid execution handles.

## Versioned artifact identity

`QuickBEAM.VM.Compiler.Contract.artifact_key/3` returns a binary SHA-256 key.
The compiler hashes the exact immutable program namespace once per evaluation,
then combines it with each function payload and profile. The identity includes:

- the compiler contract version;
- the runtime ABI version;
- the exact QuickJS/QuickBEAM ABI fingerprint and bytecode version;
- the SHA-256 serialized-bytecode digest and source digest when source is available;
- the immutable function IR, constants, and source positions;
- the exact program atom table in the shared namespace rather than repeated in every function payload;
- the lowering profile and semantic feature flags.

Keys remain binaries. They are never converted to atoms. Changing any ABI,
opcode, value representation, lowering rule, or semantic profile increments a
contract version and invalidates all artifacts.

The initial implementation has no persistent BEAM-binary cache. Compilation is
process-local and bounded by the module pool. A future disk cache must be opt-in,
size- and entry-bounded, use atomic replacement, validate a JSONCodec metadata
envelope plus the binary digest, and treat cached BEAM files as trusted
executable code. It must never deserialize arbitrary Erlang terms.

## Static module pool

The code server is global and module atoms are permanent. The pool therefore
uses exactly the statically declared names returned by
`QuickBEAM.VM.Compiler.Contract.pool_modules/0`. The initial contract reserves
32 names. Configuration may use fewer slots but cannot create names or exceed
that ceiling.

`QuickBEAM.VM.Compiler.ModulePool` now implements the lifecycle as a
supervisor-compatible singleton behind the `Compiler.ModulePool.Backend`
behavior. Compile tasks have bounded wall time and a configurable BEAM heap
ceiling. Lifecycle tests use a fake backend. The production
`Compiler.GeneratedModule` backend coordinates bounded template emission,
import validation, artifact installation, and soft-purge code retirement.

A singleton supervised pool owns these states:

```text
free
compiling(key, waiters, task)
ready(key, generation, lease_count, last_used)
retiring(key, generation)
quarantined(reason)
```

### Checkout

1. Compute the binary artifact key.
2. A ready hit increments its lease count and returns a lease containing the
   fixed module, generation, opaque token, key, and owner PID.
3. A compiling hit joins the single-flight waiter set.
4. A miss reserves a free slot or the least-recently-used ready slot with zero
   leases. If none exists, return `{:error, :compiler_pool_busy}`.
5. Lowering runs under a supervised task with instruction, form, byte, and wall
   limits. Only the pool process may install the resulting module.

The evaluation process invokes code only while holding the lease and returns it
in `after`. The pool monitors every lease owner, so timeout, memory termination,
or owner death releases leases without relying on cleanup code in that process.
A lease is valid only for its owner, key, slot generation, and pool epoch.

### Eviction and purge

Eviction is allowed only at lease count zero. The pool:

1. soft-purges any old code version;
2. deletes the current version;
3. soft-purges the deleted version;
4. increments the generation;
5. loads the new binary under the same fixed module atom.

Hard purge is forbidden because it can kill arbitrary processes. If either soft
purge reports a live code reference, the slot becomes quarantined and is not
reused. If all slots are busy or quarantined, checkout returns a typed capacity
error. Generated code must not expose BEAM funs or `{module, function}` tuples as
JavaScript values; JavaScript closures remain canonical VM function values and
acquire a fresh lease when invoked.

Pool restart increments an epoch, invalidating every old lease, and attempts to
soft-retire every reserved static slot before admitting work, including slots
outside the currently configured capacity. A slot that may still be referenced
by pre-restart code is quarantined rather than treated as free. Shutdown stops
compile tasks, rejects waiters, waits for leases for a bounded grace period, and
then applies only soft purge. Code that cannot be
safely purged remains loaded until VM shutdown.

## Compiler runtime ABI

Generated modules may call `:erlang` guard/BIF operations approved by a
BEAM-disassembly test and one module, `QuickBEAM.VM.Compiler.Runtime`. That
module is runtime ABI version 5 and delegates semantics to the existing
canonical layers:

- `Value` for primitive coercion and operators;
- `Properties` for descriptors, prototypes, and accessor actions;
- `Invocation` for call classification;
- `Async` and Promise state transitions;
- `Exceptions` for JavaScript throws and stacks;
- existing opcode-family modules for unspecialized operations.

No generated external call to `Heap`, builtin installers, process dictionaries,
or prototype compiler helpers is allowed. ABI functions return explicit actions
rather than recursively invoking JavaScript.

The current ABI contains only:

- exact canonical-frame and compact-state charging at basic-block boundaries;
- verified local/argument/stack transforms shared with opcode-family modules;
- guarded primitive operations with canonical `Value` fallback;
- canonical non-accessor property reads, owner-local global reads/writes, and explicit invocation actions;
- truthiness and verified branch selection;
- reconstruction of canonical frames and typed `%Compiler.Deopt{}` values;
- bounded runtime tuple updates for generated regions that end before the full scalar CFG.

`Compiler.GeneratedModule.ImportPolicy` inspects every generated module import
before installation. The closed allowlist contains this ABI, a fixed set of
numeric/tuple guard primitives, and the two Erlang `get_module_info` imports
emitted for every generated module. Generated variable names come only from a
fixed compiler-owned bank; no source value becomes an atom. Properties, calls,
throws, and suspension are added only with differential and resource-limit tests
for their action protocol.

## Steps, memory, timeout, and scheduling

A compiled basic block may debit its instruction count once only when every
instruction in the block is guaranteed to execute and cannot throw or suspend.
If insufficient steps remain, it deopts before the block without charging any of
its instructions. A terminal conditional still executes exactly once after the
preceding straight-line operations. This preserves the interpreter's exact `remaining_steps` contract
and `measure/2` counters. Potentially deoptimizing property and strict-global
reads occupy isolated preflight blocks: lookup classification happens without an
observable effect, the instruction is charged only after a successful preflight,
and a deoptimization resumes the still-uncharged instruction in the interpreter.

All allocation goes through canonical runtime layers and their logical memory
charges. The compiled path runs in the same monitored evaluation process, so
process heap limits, outer timeout, handler ownership, and cancellation remain
unchanged.

Generated generic blocks are capped at 256 QuickJS instructions and one function
artifact at 4,096 blocks and 4,096 lowered instructions. Generic blocks still
deoptimize at control-flow edges. The quarantined `compiler_regions: true` experiment admits binary
`{program, function, entry_pc, profile}` identities only after three encounters.
Its shared observation table is capped at `capacity * 8` (at most 256 entries),
the stable admitted set is capped at half the module pool, owner-local decisions
remain capped at 256, and generated artifacts still use only the fixed module
pool. The current executor deliberately compiles only the
first straight-line block at function entry, with at most 32 operations; it
removes a terminal branch and deoptimizes before the next instruction. Runtime
tuple updates avoid invalid early-boundary BEAM tuple-update optimization. This
experiment is disabled by default: measured Vue overhead and module churn reject
it as a production tier even though exact steps, logical memory, and results
remain canonical.

The narrower scalar profile may tail-call at
most 16 generated successor blocks while preserving per-block charging and
outer process containment. The existing `+S 1:1` ticker-gap and timeout report
remains a regression gate for compiled execution. Measurement-only compiler
instrumentation uses one fixed-size owner-local OTP `:counters` reference. It
records generated/interpreted opcode counts and fixed deoptimization/action
fields, snapshots only at evaluation completion, and never creates keys from
user input or runs exporters in generated code.

## Deoptimization state

A `%QuickBEAM.VM.Compiler.Deopt{}` contains:

- contract version and binary artifact key;
- pool generation;
- reason;
- owner PID;
- canonical `%Frame{}` and `%Execution{}`.

The initial contract permits only **before-instruction** deoptimization. The
frame PC points at the next unexecuted verified instruction; its operand stack,
locals, arguments, closure references, callers, heap, jobs, and counters are
canonical and complete. The current instruction has not been charged and has
performed no observable effect.

The dispatcher validates owner PID, contract version, artifact key width,
generation, function identity, PC range, and the active lease before calling the
interpreter. Invalid or stale state is a typed compiler infrastructure error,
not a JavaScript exception.

Initial reasons are:

- `:unsupported_opcode`;
- `:unsupported_semantics`;
- `:step_boundary`;
- `:suspension_boundary`;
- `{:guard_failed, guard}`.

After-instruction deoptimization is excluded initially because property writes,
calls, iterator steps, and Promise actions cannot be duplicated. It may be added
only as a distinct protocol carrying an explicit completed semantic action.

## Public execution policy

`QuickBEAM.VM.eval/2` remains interpreter-first. The optional tier is selected
with `engine: :compiler` after supervising `QuickBEAM.VM.Compiler`; the default
remains `engine: :interpreter`. A compiled basic block may return the documented
deoptimization action because that transition is part of the selected compiler
engine. Capacity, compile-task, load, stale-lease, and purge failures remain
typed compiler errors rather than silently restarting the whole program in the
interpreter.

The orchestration API is present for acceptance testing but remains release
quarantined until the pinned resource, scheduler, and broader native
differential gates pass.

An adaptive policy, if added, must be explicitly selected by the caller and
reported by measurement/telemetry. It still may never fall back to native
QuickJS.

The current `+S 1:1` compiler-tier Vue probe reports a 33.57 ms maximum ticker
gap against the 75 ms bound and a 51.15 ms timeout p95 against the 60 ms bound.
The opt-in scalar profile reports 35.52 ms and 51.10 ms respectively.
The pinned compiler SSR report covers 30 sequential samples plus concurrency
1/4/8 for Preact, Vue, and Svelte, with 100/100 isolated Preact renders and
successful step, memory, timeout, and cancellation checks. The Vue parity gate
also requires more than the root generated module, proving selected nested-frame
coverage. The selected Test262 gate passes 65/65 supported tests through the
interpreter and both compiler profiles.

The separate warm loop report now measures 8.23× arithmetic-loop, 7.65×
branch-loop, 5.69× local-arithmetic, 1.71× array-sum, and 5.26× object-property
speedups over the interpreter after cold compilation costs of 10.77–25.65 ms.
One-time host-profile initialization is reported separately. Those bounded
micro-workloads demonstrate that scalar generated execution can amortize
compilation; they do not replace the SSR release gate.

On the published runs, default compiler-tier sequential medians are 9.74 ms for
Preact, 60.13 ms for Vue, and 15.70 ms for Svelte. The scalar profile reports
9.66 ms, 64.45 ms, and 15.45 ms, versus interpreter medians of 8.22 ms,
49.21 ms, and 15.15 ms respectively. Vue generated-step coverage remains only
0.4% for `:pure_v1` and 1.1% for `:scalar_v1`. These separate reproducible runs
are not a paired statistical comparison, and the low useful coverage keeps the
compiler out of the release path.

### Release policy

The compiler remains release-quarantined despite those compatibility results:

- `engine: :interpreter` remains the documented default;
- compiler selection and supervision must always be explicit;
- compiler infrastructure failures never restart in another engine;
- scalar loop speedups do not imply that unsupported SSR-heavy opcode families
  have a production performance benefit;
- stable release promotion requires broader useful compiled coverage, a
  non-regressing compiler/interpreter performance comparison, and no regression
  in the existing safety gates;
- until promotion, compiler API compatibility may change within the development
  major release.

## Prototype analysis map

Prototype code is not copied as a subsystem. Each part has one bounded target:

| Prototype concept | Decision and canonical target |
| --- | --- |
| CFG/basic-block discovery | Adapt the pure graph algorithm to current v26 instruction tuples. Targets remain verified instruction indexes. |
| Stack analysis | Do not extract. `StackVerifier` remains authoritative; lowering consumes its verified heights and joins. |
| Opcode support analysis | Keep the conservative `:pure_v1` allowlist and add an explicit `:scalar_v1` property/call extension. Every other opcode emits a before-instruction deopt. |
| Local/stack lowering | Adapt scalar block arguments only under fixed stack/slot/form bounds. Rebuild canonical `%Frame{}` at deoptimization and exclude captured locals. |
| Value lowering | Use allowlisted guarded BEAM primitives with canonical `Value` fallback. Do not retain prototype coercion or object tags. |
| Property lowering | Initially deopt. Later call `Properties` and preserve its accessor boundary actions. |
| Call lowering | Initially deopt. Later call `Invocation`; calls never recursively enter generated code or the interpreter. |
| Promise/async lowering | Initially deopt before Promise, host-call, and `await` instructions. Later preserve `Async`, Promise jobs, and typed suspension boundaries. |
| Throw/catch lowering | Initially deopt before potentially throwing instructions. Later route explicit actions through `Exceptions`. |
| Runtime helpers/heap | Reject. The prototype process dictionary, heap, object tags, and runtime state have no compiler ABI role. |
| Form optimizer | Defer until the unspecialized pure compiler is differential-test clean; every optimization needs equivalent deopt points and accounting. |
| Diagnostics/disassembly tests | Adapt with v26 fixtures, source positions, artifact keys, and the external-call allowlist. |

This mapping permits reuse of isolated algorithms and form-emission techniques,
not prototype runtime modules or fallback behavior.

## Extraction order

1. **Complete:** land contract types, static slot names, and invariant tests.
2. **Complete:** implement the supervised pool with a fake backend; prove bounds,
   owner monitoring, generations, single-flight compilation, bounded shutdown,
   and quarantine.
3. **Complete:** add the minimal runtime ABI, generated-module emitter and import
   policy, and production soft-purge code lifecycle.
4. **Complete:** adapt bounded v26 CFG/basic-block analysis and deterministic
   `:pure_v1` block plans.
5. **Complete:** execute literals, stack/local operations, primitive values, and
   terminal branches through the canonical ABI.
6. **Complete:** resume validated before-instruction deoptimization in the
   interpreter.
7. **Complete for the initial pure subset:** emit specialized fixed-name block
   and step clauses without dynamic atoms, and cover decoded expressions plus
   function arguments/locals differentially against the interpreter.
8. Expand decoded JavaScript and native differential coverage, then run exact
   limit and scheduler gates.
9. Expand one resumable semantic family at a time.

## Acceptance gates

Before enabling compiler execution outside tests:

- 100,000 unique artifact keys leave atom count unchanged after pool startup;
- loaded compiler modules never exceed the configured static capacity;
- active leases cannot be evicted and owner death releases them;
- duplicate concurrent compilation is single-flight;
- stale generation/epoch leases are rejected;
- soft-purge failure quarantines a slot and never hard-purges;
- interpreter and compiler results, JavaScript errors, steps, and logical memory
  match for every compiled opcode family;
- step, memory, timeout, cancellation, and `+S 1:1` gates pass;
- async/host operations deopt and resume without duplicate effects;
- generated-module disassembly contains only allowed external calls;
- no compiler path reaches native QuickJS.
