# Prototype Branch Delta Audit

This audit compares the clean `beam-interpreter-v2` implementation with
`origin/beam-vm-interpreter`, reviewed in `.worktrees/beam-vm-review`. It is an
extraction guide, not a merge plan.

The prototype contains useful semantic algorithms and a large test corpus, but
its mutable runtime is built around process-dictionary storage and a different
execution contract. No production source file should be copied without being
adapted to the current owner-local `%QuickBEAM.VM.Execution{}` model, generated
QuickJS v26 ABI, resource limits, and resumable invocation machinery.

## Executive decision

| Area | Decision | Reason |
|---|---|---|
| ABI, decoding, verification | Superseded | Current code uses generated QuickJS v26 metadata, fingerprints, checksums, bounds, and structural verification. |
| Interpreter kernel | Superseded structurally | Current explicit frames, boundaries, limits, async coroutines, and owner event loop are the production foundation. |
| Heap storage | Reject prototype implementation | Prototype heap storage uses the process dictionary; current heap is explicit evaluation state. |
| Error semantics | Adapt algorithms and tests | Prototype has useful Error hierarchy/prototype behavior, but construction and stack capture depend on the old heap and runtime macros. |
| Object enumeration | Adapt small algorithms and tests | Own-key filtering/order behavior is useful and maps cleanly onto current descriptors. |
| Arrays | Extract tests first; adapt selected algorithms | Prototype implementation is broad and tightly coupled to its object model. Sparse-hole and length algorithms are valuable. |
| Iterators | Adapt after canonical invocation/Symbol work | Protocol and IteratorClose logic are useful, but direct recursive invocation is incompatible with resumable callbacks. |
| Promises | Reject core implementation; adapt combinator tests/algorithms | Current detached async frames and reaction scheduler supersede the prototype Promise store. Iterable combinator logic remains useful. |
| Coercion/arithmetic | Adapt pure semantic functions and tests | The split into arithmetic, comparison, equality, and coercion is a good target, but object coercion and throws use prototype representations. |
| Test262 support | Superseded harness; extract test ideas | Current runner is pinned, differential, typed with JSONCodec, and classifies failures. Prototype paths and skip rationale remain useful input. |
| Preact SSR | Superseded | Current fixture performs real async rendering, native parity, and concurrent isolated reuse. |
| Web/Node APIs | Defer | Outside the first explicit SSR profile. |
| BEAM compiler | Quarantine for later extraction | It targets the prototype runtime ABI, creates dynamic module atoms, and relies on interpreter fallback and process-local runtime state. |

## Scale and coupling

The prototype has 331 VM source files and 103 VM test files. The clean branch
currently has 43 VM source files and 13 VM test files. Breadth in the prototype
is not evidence that a subsystem is production-ready.

At least 27 prototype VM modules directly use process-dictionary operations.
Core modules that do not call `Process.get/put` themselves still call the
prototype heap facade, whose low-level store implementation does. For example:

- `lib/quickbeam/vm/heap/store.ex` stores objects, arrays, shapes, and cells with
  `Process.get/put`;
- `lib/quickbeam/vm/runtime/errors.ex` creates errors through that heap;
- `lib/quickbeam/vm/runtime/array.ex`, `runtime/promise.ex`, and
  `semantics/iterators.ex` transitively depend on it.

The five broad prototype runtime files reviewed for this audit total 5,304 lines:

- `runtime/errors.ex` — 451;
- `runtime/object/enumeration.ex` — 231;
- `runtime/array.ex` — 3,131;
- `runtime/promise.ex` — 1,082;
- `semantics/iterators.ex` — 409.

They should not be introduced as one extraction change.

## Detailed extraction map

### 1. Errors and constructor identity

Prototype sources:

- `lib/quickbeam/vm/runtime/errors.ex`
- `lib/quickbeam/vm/heap.ex` (`make_error/2`)
- `lib/quickbeam/vm/js_throw.ex`
- `lib/quickbeam/vm/stacktrace.ex`
- `test/vm/runtime/constructors_test.exs`

Reusable concepts:

- the standard error-name set;
- `Error.prototype` plus derived prototype topology;
- non-enumerable `name`, `message`, and stack-related properties;
- constructor-specific prototypes for `instanceof`;
- `AggregateError.errors` ordering;
- preserving catchable JavaScript objects until the API boundary;
- constructor and descriptor tests.

Do not copy:

- `Heap.make_error/2`, because it discovers constructors through process-local
  global caches and stores objects by raw references;
- `throw({:js_throw, ...})` control flow;
- stack attachment based on prototype interpreter context;
- builtin definition macros as a prerequisite for the first error slice.

Current adaptation target:

1. Add an error-object kind or internal slot to the current owner-local heap.
2. Install `Error`, `TypeError`, `ReferenceError`, `RangeError`, and required
   prototypes in `Builtins`.
3. Convert VM-generated catchable errors into owner-local references.
4. Resolve name/message/frames from the owning execution only when uncaught.
5. Preserve `%QuickBEAM.JSError{}` as the stable external representation.

This is the highest-value immediate extraction and closes the remaining selected
Test262 constructor-identity failure.

### 2. Own-property enumeration

Prototype sources:

- `lib/quickbeam/vm/runtime/object/enumeration.ex`
- `lib/quickbeam/vm/object_model/own_property.ex`
- `test/vm/object_descriptors_order_test.exs`
- `test/vm/object_keys_test.exs`
- `test/vm/object_own_property_primitives_test.exs`

Reusable concepts:

- numeric keys first, then string insertion order, then symbols;
- distinction between enumerable keys and all own property names;
- descriptor-aware `Object.keys`, values, and entries;
- UTF-16 indexed string own properties;
- tests for non-enumerable properties and descriptor order.

Current adaptation target:

- extend current `Heap.own_keys/2` with an all-own-keys operation rather than
  copying prototype map/shape traversal;
- implement `Object.getOwnPropertyNames` over current `Property` structs;
- add only the small `propertyHelper.js` dependencies required by the pinned
  conformance manifest.

The prototype implementation is useful as a specification checklist, not as
source code.

### 3. Arrays and sparse holes

Prototype sources:

- `lib/quickbeam/vm/runtime/array.ex`
- `lib/quickbeam/vm/object_model/array_exotic.ex`
- `lib/quickbeam/vm/object_model/array_exotic_get.ex`
- `lib/quickbeam/vm/heap/arrays.ex`
- `test/vm/runtime/array_test.exs`
- typed-array and array descriptor tests

Reusable concepts:

- maximum array length and safe-integer bounds;
- hole-aware `HasProperty` before callback invocation;
- inherited values at sparse indices;
- length updates around non-configurable elements;
- iterator and species edge-case tests;
- mutation ordering for push/pop/shift/unshift/splice.

Do not copy:

- `:array` plus process-dictionary object storage;
- recursive callback invocation from runtime methods;
- the full 3,131-line API surface before profile demand;
- typed-array branches before ordinary arrays are conformant.

Extraction sequence:

1. Port sparse `map/filter/reduce/some/forEach` differential tests.
2. Add a canonical current-heap `has_index`/`get_index` operation.
3. Update resumable native callback frames to skip holes where required.
4. Add precise partial length truncation around non-configurable elements.
5. Add further methods only when selected Test262 or SSR code requires them.

### 4. Iterators and iterable Promise combinators

Prototype sources:

- `lib/quickbeam/vm/semantics/iterators.ex`
- `lib/quickbeam/vm/execution/iterator_state.ex`
- `lib/quickbeam/vm/interpreter/ops/iterators.ex`
- `test/vm/iterator_semantics_test.exs`
- iterator portions of `runtime/promise.ex`

Reusable concepts:

- `GetIterator`, `IteratorNext`, result-object validation, and `IteratorClose`;
- close-on-abrupt-completion tests;
- custom array iterator replacement/deletion behavior;
- string iteration by code point while string indexing remains UTF-16;
- Promise combinator ordering and iterator closing.

Do not copy:

- recursive `Invocation.invoke_with_receiver` loops;
- prototype tagged values such as `{:obj, ref}` and `{:list_iter, ...}` without
  adapting them to current owner-local references;
- synchronous collection of arbitrary iterators, which can bypass limits and
  resumable JavaScript callbacks.

Current adaptation target:

- represent iterator operations as explicit resumable boundaries/jobs;
- use the same canonical invocation path as getters, setters, reactions, and
  `Object.assign`;
- charge steps and memory on every transition;
- make `Promise.all/allSettled/any/race` consume iterables through that layer.

### 5. Promise runtime

Prototype source:

- `lib/quickbeam/vm/runtime/promise.ex`
- `lib/quickbeam/vm/promise.ex`
- `lib/quickbeam/vm/job_queue.ex`

Current status:

The clean branch already supersedes the prototype in the production-critical
areas: detached async frames, multiple suspended coroutines, FIFO reactions,
thenable getter ordering, handler tasks, cancellation, Promise adoption,
self-resolution protection, and process-owned event-loop state.

Potential extraction:

- constructor/species tests;
- iterable combinator algorithms after iterator support;
- iterator-close-on-rejection cases;
- capability tests for subclassed Promise constructors.

Reject the prototype Promise store and microtask queue. They use the old heap and
do not provide the current owner/task containment model.

### 6. Value semantics

Prototype sources:

- `lib/quickbeam/vm/semantics/values.ex`
- `lib/quickbeam/vm/semantics/arithmetic.ex`
- `lib/quickbeam/vm/semantics/comparison.ex`
- `lib/quickbeam/vm/semantics/equality.ex`
- `lib/quickbeam/vm/semantics/coercion.ex`

Reusable concepts:

- splitting pure semantic families;
- infinity, NaN, negative zero, BigInt, and Symbol cases;
- differential/property tests;
- inlining only after semantics are centralized.

Adaptation rule:

Pure number/string clauses may be ported with focused tests. Any clause that
reads prototype objects, throws through `JSThrow`, or invokes user code must be
rewritten against current `Execution`, `Heap`, and resumable invocation.

This split is a useful model for decomposing the current `Value` and
`Interpreter`, but the prototype module graph is too fragmented to copy.

### 7. Interpreter decomposition

Prototype sources include 40-plus opcode modules and dozens of object-model
micro-modules. The separation demonstrates useful boundaries, but it also
created overlapping routes for get/put/call semantics and a very large internal
surface.

Target decomposition for the clean branch should be smaller:

1. `Invocation` — ordinary, constructor, bound, builtin, and host calls;
2. `Properties` — get/set/define/delete/prototype and accessor boundaries;
3. `Async` — Promise resolution, jobs, coroutines, and handler completion;
4. `Exceptions` — throw values, catch/finally unwinding, and external errors;
5. `Values` — coercion, arithmetic, equality, comparison, and UTF-16;
6. opcode-family dispatch modules that call those canonical layers.

No opcode module may implement an alternative property, invocation, or Promise
algorithm.

### 8. BEAM compiler

Prototype sources:

- `lib/quickbeam/vm/compiler.ex`
- `lib/quickbeam/vm/compiler/analysis/*`
- `lib/quickbeam/vm/compiler/lowering/*`
- `lib/quickbeam/vm/compiler/runtime_abi/*`
- `lib/quickbeam/vm/compiler/runtime_helpers/*`
- compiler tests

Potentially reusable later:

- CFG and stack analyses;
- basic-block lowering structure;
- Erlang abstract-form emission patterns;
- diagnostics and disassembly tests;
- the concept of one explicit runtime ABI;
- resource caps on instruction, atom, constant, and generated-form counts.

Release blockers in the prototype compiler:

- generated module names create atoms from hashes and loaded modules are cached,
  so the design needs a bounded reusable module pool and purge strategy;
- generated code targets prototype `RuntimeABI`, object tags, process heap, and
  invocation context;
- semantic fallback assumes the prototype interpreter and heap;
- runtime step, stack, memory, async, and cancellation containment are not the
  clean interpreter's limits;
- compiler correctness tests mix broad runtime support with lowering behavior;
- QuickJS v25 assumptions must be regenerated for v26.

Compiler extraction gate:

1. Current interpreter semantic layers are stable and independently tested.
2. A small versioned runtime ABI is documented.
3. Compiled operations call that ABI rather than prototype helpers.
4. A bounded module pool prevents atom/module leaks.
5. Runtime limits and async suspension have compiled-path acceptance tests.
6. Unsupported compiled regions deopt explicitly to verified interpreter state;
   they never fall back to native execution.

Until those gates hold, the compiler remains quarantined.

## Test extraction policy

Prototype tests are generally more reusable than prototype implementations.
For each selected area:

1. copy the JavaScript scenario, not prototype setup helpers;
2. run it through current native QuickJS and `QuickBEAM.VM`;
3. remove `mode: :beam`, process-dictionary resets, and compiler assumptions;
4. preserve a source link in the commit message or test comment when useful;
5. keep only cases in the declared profile or conformance roadmap;
6. classify unsupported cases explicitly rather than weakening assertions.

High-value test groups to adapt next:

- error constructor/prototype and catch identity;
- object own names and descriptor order;
- sparse array callback behavior;
- iterator result validation and close-on-abrupt-completion;
- Promise iterable combinator ordering and closing;
- pure coercion and arithmetic sentinels.

## Ordered long-term plan

### Phase A — close the current bounded baseline (complete)

- Adapted Error hierarchy concepts and tests.
- Adapted `Object.getOwnPropertyNames` semantics and required harness helpers.
- Raised the selected Test262 baseline from 88.9% to 100%.

### Phase B — establish canonical semantic modules (complete)

- Property semantics now live behind one canonical property layer, including
  explicit getter/setter actions used by the interpreter, built-ins, Promise
  thenable lookup, and exception conversion.
- Invocation now has one canonical planner for ordinary, closure, bound,
  constructor, built-in, Promise, and host calls. The interpreter executes its
  explicit actions to preserve resumable scheduling and exception unwinding.
- Async state transitions now have one canonical layer for async frame entry,
  coroutine detachment/resumption, await suspension, reactions, thenables,
  Promise-boundary completion, and supervised handler startup.
- Exception materialization, catch lookup, frame and native-boundary unwinding,
  async stack preservation, Promise-boundary rejection, and public error
  conversion now share one canonical exception layer.
- Value coercion, arithmetic, equality, comparison, bitwise operations,
  `typeof`, and UTF-16 string operations now share one canonical value layer.
- Keep the current tests and SSR fixture green after each extraction.
- Avoid reproducing the prototype's hundreds of overlapping modules.

### Interpreter decomposition (complete)

- Literal and operand-stack opcodes now live in one stack family module.
- Coercion, arithmetic, comparison, bitwise, value-test, `in`, and `instanceof`
  opcodes now live in one value family module.
- Control-flow opcodes now classify branches, catches, returns, throws, and
  awaits as explicit interpreter actions.
- Local and closure opcodes now own argument/local slots, closure cells,
  globals, atom resolution, and function-closure allocation.
- Object opcodes now own object/array/RegExp construction, field definitions,
  property access, resumable accessor actions, deletion, and enumeration.
- Invocation opcodes now decode ordinary, method, tail, and constructor call
  stacks into explicit canonical invocation actions.
- Family-owned opcode lists are the interpreter's compile-time routing source.
- The interpreter now owns only routing, stepping, resource checks, action
  execution, native callback frames, and boundary completion.

### Declarative builtin migration (in progress)

- Adapted the prototype's useful spec/installer idea without its process-local
  heap, loaded-module discovery, giant multi-form macro surface, or generated
  fallback dispatch.
- Builtin declarations now compile to immutable validated specs and install from
  an explicit deterministic profile registry.
- DSL v2 uses parenthesis-free handler-first declarations with inferred JS
  names, typed constants/data/accessors, profile and dependency metadata, and
  separate compiler, validator, installer, and runtime-contract modules.
- Handlers use stable module/function tokens and explicit call contexts through
  canonical invocation semantics; resumable actions are typed and malformed
  results fail as infrastructure contract errors.
- Migrated `Math`, Promise, Symbol, Set, the Error hierarchy, shared Function
  methods, `String.fromCharCode`, `Array.isArray`, all currently supported Array
  prototype methods, and all currently supported Object statics and prototype
  methods with real function objects and descriptor, `name`, and `length`
  metadata.
- `Object.assign` and Array callback methods prove that DSL handlers can return
  canonical resumable actions without recursively invoking JavaScript.
- Descriptor-heavy Object methods now share canonical descriptor validation;
  sparse `slice`/`concat` preserve holes and `join` handles holes/nullish values.
- String and Number primitive methods now resolve through their installed DSL
  prototype objects for both primitives and boxed values; numeric radix output
  is normalized to JavaScript lowercase form.
- Promise construction, static combinators, and reaction methods now use full
  constructor DSL topology. Combinators share a canonical iterable boundary
  for sparse arrays, insertion-ordered sets, strings, internal lists, and custom
  `Symbol.iterator` objects.
- Custom iterator getters, factories, cached `next` methods, and accessor-backed
  `done`/`value` reads resume through explicit boundaries; computed Symbol
  methods and fields are supported without recursive JavaScript execution.
- Constructor prototype parents, prototype kind/callability, default and Error
  prototype registration, and Symbol-keyed aliases are explicit installer
  topology. Object/Function bootstrap cycles and primitive constructors are
  declarative; the hard-coded constructor table and legacy object/error/set/
  function pseudo-method tokens have been removed.

### Phase C — expand conformance by profile demand

- Added differential sparse-array tests and hole-aware native callback frames;
  callbacks skip holes, `map` preserves them, and `reduce` finds the first
  present element when no initial value is supplied.
- Expand Symbol APIs and iterator consumers only when required by the selected
  compatibility profile.
- Expanded the pinned Test262 manifest to 69 selected tests with 65/65
  supported cases passing and four explicit asynchronous skips.
- Add decoder mutation fuzzing.

### Phase D — production hardening

- Runtime and context-pool shutdown now use serialized running → stopping →
  joined lifecycle states, and resource creation cannot leave a destructor
  pointing at freed startup data.
- Sync-call result publication remains under its slot mutex through wakeup;
  pool RuntimeData pointers are removed under the registry mutex before context
  destruction. Repeated concurrent lifecycle and callSync shutdown stress tests
  pass without crashes.
- Continue auditing cancellation, queued-payload cleanup, and owner-local
  shutdown.
- Publish scheduler, memory, timeout, and performance results.
- Freeze the supported SSR compatibility matrix.

### Phase E — optional compiler extraction

- Extract analyses and lowering patterns only after the runtime ABI is stable.
- Introduce a bounded module pool.
- Add explicit deoptimization to interpreter states.
- Keep compiler and interpreter differential tests mandatory.

## Immediate next action

Add bounded mutation fuzzing for bytecode decoding and verification, then
publish scheduler, timeout, memory, and Preact SSR measurements for the frozen
SSR compatibility profile.
