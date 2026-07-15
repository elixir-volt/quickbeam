# Bounded BEAM compiler contract

Status: design gate for the optional compiler. No prototype compiler source is
approved for extraction until this contract and its acceptance tests are in
place.

## Scope

The compiler is an optimization tier for an already verified
`QuickBEAM.VM.Program`. It is not a JavaScript parser, a third execution engine,
or a native fallback. QuickJS still produces bytecode, the current decoder and
verifier remain authoritative, and all mutable JavaScript state remains owned by
one evaluation process.

The first extraction slice is intentionally narrow: verified basic blocks
containing literals, stack movement, local reads/writes, primitive value
operations, and terminal branches. The initial unspecialized lowering emits a
bounded immutable block plan and delegates those operations to the canonical
runtime ABI. Calls, accessors, constructors, iterators, exceptions, Promise
operations, host calls, and `await` deopt before their instruction until their
resumable compiler ABI exists.

## Non-negotiable invariants

1. Compiling unbounded user input never creates an unbounded number of atoms.
2. Generated code never owns a heap, globals, cells, Promise state, jobs, or
   handler tasks. It receives and returns canonical `%Frame{}` and
   `%Execution{}` values.
3. Generated code calls one versioned compiler runtime ABI. It does not call
   heap internals or copy JavaScript semantic algorithms.
4. Every transition to the interpreter is an explicit, validated deoptimization
   at a verified instruction boundary.
5. A timeout, memory failure, step failure, throw, or suspension has the same
   external result and owner cleanup as interpreter execution.
6. No compiler failure invokes native QuickJS. An explicitly selected compiler
   mode returns a typed error or deoptimization result.
7. Loaded code is reused only while protected by a live pool lease. Stale
   module/function tuples are never valid execution handles.

## Versioned artifact identity

`QuickBEAM.VM.Compiler.Contract.artifact_key/3` returns a binary SHA-256 key. It
includes:

- the compiler contract version;
- the runtime ABI version;
- the exact QuickJS/QuickBEAM ABI fingerprint and bytecode version;
- the SHA-256 serialized-bytecode digest and source digest when source is available;
- the immutable function IR, constants, atom table, and source positions;
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
module is the versioned ABI and delegates semantics to the existing canonical
layers:

- `Value` for primitive coercion and operators;
- `Properties` for descriptors, prototypes, and accessor actions;
- `Invocation` for call classification;
- `Async` and Promise state transitions;
- `Exceptions` for JavaScript throws and stacks;
- existing opcode-family modules for unspecialized operations.

No generated external call to `Heap`, builtin installers, process dictionaries,
or prototype compiler helpers is allowed. ABI functions return explicit actions
rather than recursively invoking JavaScript.

The first ABI now contains only:

- exact step charging at basic-block boundaries;
- verified local/argument/stack transforms over `%Frame{}` through existing
  opcode-family modules;
- primitive unary/binary operations through `Value`;
- truthiness and verified branch selection;
- construction of a typed `%Compiler.Deopt{}`.

`Compiler.GeneratedModule.ImportPolicy` inspects every generated module import
before installation. The closed initial allowlist contains this ABI plus the two
Erlang `get_module_info` imports emitted for every generated module. Properties, calls,
throws, and suspension are added only with differential and resource-limit tests
for their action protocol.

## Steps, memory, timeout, and scheduling

A compiled basic block may debit its instruction count once only when every
instruction in the block is guaranteed to execute and cannot throw or suspend.
If insufficient steps remain, it deopts before the block without charging any of
its instructions. Blocks with dynamic exits charge at individual instruction
boundaries. This preserves the interpreter's exact `remaining_steps` contract
and `measure/2` counters.

All allocation goes through canonical runtime layers and their logical memory
charges. The compiled path runs in the same monitored evaluation process, so
process heap limits, outer timeout, handler ownership, and cancellation remain
unchanged.

Generated basic blocks are capped at 256 QuickJS instructions and call another
module function at control-flow edges. The existing `+S 1:1` ticker-gap and
timeout report remains a regression gate for compiled execution.

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

`QuickBEAM.VM.eval/2` remains the interpreter API. Compiler execution will be an
explicit option or API. The first compiler mode does not silently interpret an
unsupported whole program. A compiled basic block may return the documented
deoptimization action because that transition is part of the selected compiler
engine. Capacity, compile-task, load, stale-lease, and purge failures remain
typed compiler errors.

An adaptive policy, if added, must be explicitly selected by the caller and
reported by measurement/telemetry. It still may never fall back to native
QuickJS.

## Prototype analysis map

Prototype code is not copied as a subsystem. Each part has one bounded target:

| Prototype concept | Decision and canonical target |
| --- | --- |
| CFG/basic-block discovery | Adapt the pure graph algorithm to current v26 instruction tuples. Targets remain verified instruction indexes. |
| Stack analysis | Do not extract. `StackVerifier` remains authoritative; lowering consumes its verified heights and joins. |
| Opcode support analysis | Replace broad fallback analysis with a closed `:pure_v1` allowlist. Every other opcode emits a before-instruction deopt. |
| Local/stack lowering | Adapt abstract-form patterns to transformations over canonical `%Frame{}` through the compiler runtime ABI. |
| Value lowering | Call `Value`; do not retain prototype coercion or object tags. Guards deopt before an instruction when specialization assumptions fail. |
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
4. **Complete:** adapt bounded v26 CFG/basic-block analysis and unspecialized
   `:pure_v1` block-plan emission.
5. **Complete:** execute literals, stack/local operations, primitive values, and
   terminal branches through the canonical ABI.
6. **Complete:** resume validated before-instruction deoptimization in the
   interpreter.
7. Expand differential tests from synthetic verified functions to decoded
   JavaScript fixtures, then specialize generated forms without changing the ABI.
8. Run interpreter/compiler/native differential tests plus exact limit and
   scheduler gates.
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
