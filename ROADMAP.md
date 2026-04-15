# QuickBEAM Roadmap: BEAM-Native JS Execution

## Why

Benchmarks (April 2026, M-series Mac, Zig ReleaseSafe):

```
Benchmark         QJS (NIF)     BEAM (Elixir)    Ratio
──────────────────────────────────────────────────────
sum 1M              25,274 µs       715 µs       BEAM 35x faster
sum 10M            247,400 µs     7,271 µs       BEAM 34x faster
fibonacci(30)       73,183 µs     2,311 µs       BEAM 32x faster
arithmetic 10M     220,736 µs    45,104 µs       BEAM  5x faster
```

BEAM's JIT-compiled tail calls beat native QuickJS by 5-35x on numeric workloads.
The question was: can we run JS on BEAM and still be fast?

**Yes.** The key insight from measuring different interpreter architectures:

```
Interpreter approach                          µs     vs Direct BEAM
──────────────────────────────────────────────────────────────────
Direct BEAM (tail-recursive)                  757      1.0x
Flat fn args, one fn per opcode              3,345      4.4x
Binary bytecode + fn clause dispatch         18,868    24.9x
Binary bytecode + case dispatch              17,974    23.7x
Process Dictionary (per-variable)            15,259    20.2x
Map state (update per opcode)                40,936    54.1x
ETS table (per-variable)                     64,645    85.4x
```

The "flat fn args" approach is **4.4x slower** than direct BEAM but still **7.5x faster
than native QuickJS**. This means a well-designed BEAM interpreter already beats
QuickJS without any JIT compilation. The JIT (compiling hot JS to BEAM bytecode)
is an optimization that closes the 4.4x gap to 1x — important but not existential.

---

## Architecture

```
JS source
    │
    ▼
QuickJS compiler (existing, via NIF) ───► QJS bytecode binary
                                              │
                                              ▼
                                    ┌─ Pre-decode (one-time) ─┐
                                    │ Binary → instruction     │
                                    │ tuple array + atom table │
                                    └────────────┬────────────┘
                                                 │
                    ┌────────────────────────────┴───────────────────────┐
                    │                BEAM Process                        │
                    │                                                    │
                    │   Instruction Tuple Array                          │
                    │        │                                           │
                    │        ▼                                           │
                    │   step(op, stk, locs, frefs, ...)                  │
                    │        │                                           │
                    │   ┌────┴────┐                                      │
                    │   │  187 fn │  one defp per opcode                 │
                    │   │ clauses │  flat args, no map/tuple alloc       │
                    │   └────┬────┘                                      │
                    │        │                                           │
                    │        ▼                                           │
                    │   JS Runtime                                       │
                    │   (only for dynamic ops: coercion, prototypes,     │
                    │    property chains, typeof, etc.)                  │
                    │                                                    │
                    └────────────────────────────────────────────────────┘
```

**State representation** (flat function args, zero heap allocation in hot loop):

```elixir
# Hot-path state: all flat args, no struct/map/tuple wrapping
step(op, stk, locs, frefs, atom_tab, const_pool, ip, gas)
#  op         — current instruction (pre-decoded tuple, e.g. {:add, []})
#  stk        — JS stack (Elixir list, prepend/pop = O(1))
#  locs       — locals + args (tuple, elem/put_elem = O(1))
#  frefs      — closure/var references (tuple)
#  atom_tab   — atom string table (tuple of binaries)
#  const_pool — constant pool (tuple of pre-converted BEAM terms)
#  ip         — instruction pointer (integer index into instruction array)
#  gas        — reduction counter for BEAM scheduler cooperation
```

---

## Phase 0: Bytecode Loader + Decoder

**Goal**: Parse QJS bytecode binary into a BEAM-friendly format.

### 0.1 Bytecode Loader

QuickJS `JS_WriteObject` produces a serialized binary containing:
- Header: magic bytes, version flags
- Atom table: all string atoms used in the module
- Constant pool: numbers, strings, functions, object templates
- Per-function: `JSFunctionBytecode` — args, vars, stack_size, bytecode bytes, closure vars

QuickBEAM already has `do_compile` in `worker.zig` that produces this binary.
We reuse the existing QuickJS compiler — no need to write our own.

Deliverables:
- `QuickBEAM.BeamVM.Bytecode` — parses QJS bytecode binary into Elixir structs

```elixir
defmodule QuickBEAM.BeamVM.Bytecode do
  @type function_id :: non_neg_integer()

  @type t :: %__MODULE__{
    atoms: tuple(),           # {<<"foo">>, <<"bar">>, ...}
    constants: tuple(),       # {42, "hello", {:fn_ref, 3}, ...}
    functions: %{function_id() => Function.t()},
    module_name: binary()
  }

  @type Function :: %Function{
    id: function_id(),
    name: binary(),
    arg_count: non_neg_integer(),
    var_count: non_neg_integer(),
    stack_size: non_neg_integer(),
    # Pre-decoded instructions: tuple of {opcode_atom, args}
    # e.g. {{:push_i32, [42]}, {:get_loc, [0]}, {:add, []}, {:return, []}}
    instructions: tuple(),
    # Index maps for control flow targets (label → instruction index)
    labels: %{non_neg_integer() => non_neg_integer()},
    # Closure variable descriptors
    closure_vars: [ClosureVar.t()],
    # Source location info (for errors/debugging)
    line_number: pos_integer(),
    filename: binary()
  }
end
```

### 0.2 Opcode Decoder

246 opcodes (187 core + 59 short-form aliases). 32 byte formats.

**Key design decision**: decode binary bytecode to Elixir terms **once** at load time,
not on every step. The instruction array is a tuple for O(1) indexed access.

Short-form aliases expand to their canonical form at decode time:
- `get_loc0` → `{:get_loc, [0]}`
- `push_0` → `{:push_i32, [0]}`
- `call0` → `{:call, [0]}`

This means the interpreter only needs to handle ~187 distinct opcodes.

Deliverables:
- `QuickBEAM.BeamVM.Decoder` — converts raw QJS bytecode bytes → instruction tuple

```elixir
defmodule QuickBEAM.BeamVM.Decoder do
  @spec decode(binary(), atoms :: tuple(), constants :: tuple()) ::
    {:ok, {instructions :: tuple(), labels :: map()}} | {:error, term()}

  # Each instruction is a tuple: {opcode_atom, [args...]}
  # Examples:
  #   {:push_i32, [42]}
  #   {:get_loc, [3]}
  #   {:add, []}
  #   {:if_false, [label_42]}   # labels resolved to instruction indices
  #   {:call, [3]}              # arg count
  #   {:get_field, [atom_index]}
end
```

Opcode groups (implementation priority):

| Priority | Group | Count | Core ops | Notes |
|----------|-------|-------|----------|-------|
| 1 | Stack manipulation | 21 | ~8 | push/dup/drop/swap — trivial |
| 2 | Variables | 58 | ~6 | get_loc/put_loc/get_arg via tuple index |
| 3 | Binary ops | 43 | 20 | add/sub/lt/eq etc. — JSRuntime for coercion |
| 4 | Control flow | 10 | 4 | if_true/if_false/goto/return |
| 5 | Call/control | 24 | 8 | call/return/throw/apply |
| 6 | Property access | 16 | 10 | get_field/put_field — prototype walk |
| 7 | Iterators | ~15 | 6 | for_in/for_of/iterator_next |
| 8 | Scope/closure | 7 | 4 | make_var_ref/closure_var — boxed cells |
| 9 | Helpers | 9 | 5 | typeof/delete/is_undefined |
| 10 | Short forms | 59 | 0 | Expanded at decode time |

**Estimated effort**: 2-3 weeks
**Lines of code**: ~3000

---

## Phase 1: Interpreter Core

**Goal**: Run any pre-decoded JS function in a BEAM process.

### 1.1 The `step` Function

One `defp` per opcode. All state as flat function arguments. No struct, no map,
no ETS in the hot path.

```elixir
defmodule QuickBEAM.BeamVM.Interpreter do
  # Fetch next instruction and dispatch
  defp next(stk, locs, frefs, insns, ip, gas) do
    case gas do
      0 -> {:reduce, stk, locs, frefs, ip}
      _ ->
        {op, args} = elem(insns, ip)
        step(op, args, stk, locs, frefs, insns, ip + 1, gas - 1)
    end
  end

  # ── Stack manipulation ──
  defp step(:push_i32, [val], stk, locs, frefs, insns, ip, gas) do
    next([val | stk], locs, frefs, insns, ip, gas)
  end

  defp step(:drop, [], [_ | stk], locs, frefs, insns, ip, gas) do
    next(stk, locs, frefs, insns, ip, gas)
  end

  defp step(:dup, [], [a | _] = stk, locs, frefs, insns, ip, gas) do
    next([a | stk], locs, frefs, insns, ip, gas)
  end

  defp step(:swap, [], [b, a | rest], locs, frefs, insns, ip, gas) do
    next([a, b | rest], locs, frefs, insns, ip, gas)
  end

  # ── Variables ──
  defp step(:get_loc, [idx], stk, locs, frefs, insns, ip, gas) do
    next([elem(locs, idx) | stk], locs, frefs, insns, ip, gas)
  end

  defp step(:put_loc, [idx], [val | stk], locs, frefs, insns, ip, gas) do
    next(stk, put_elem(locs, idx, val), frefs, insns, ip, gas)
  end

  defp step(:get_arg, [idx], stk, locs, frefs, insns, ip, gas) do
    # args are stored in locs[0..arg_count-1]
    next([elem(locs, idx) | stk], locs, frefs, insns, ip, gas)
  end

  # ── Binary ops (delegate to JSRuntime for JS coercion) ──
  defp step(:add, [], [b, a | rest], locs, frefs, insns, ip, gas) do
    next([JSRuntime.add(a, b) | rest], locs, frefs, insns, ip, gas)
  end

  defp step(:sub, [], [b, a | rest], locs, frefs, insns, ip, gas) do
    next([JSRuntime.sub(a, b) | rest], locs, frefs, insns, ip, gas)
  end

  # ... all 20 binary ops

  # ── Control flow ──
  defp step(:if_false, [target], [val | stk], locs, frefs, insns, ip, gas) do
    if val == false or val == nil do
      next(stk, locs, frefs, insns, target, gas)
    else
      next(stk, locs, frefs, insns, ip, gas)
    end
  end

  defp step(:goto, [target], stk, locs, frefs, insns, _ip, gas) do
    next(stk, locs, frefs, insns, target, gas)
  end

  defp step(:return, [], [val | _], _locs, _frefs, _insns, _ip, _gas) do
    {:return, val}
  end

  # ── Property access ──
  defp step(:get_field, [atom_idx], [obj | stk], locs, frefs, insns, ip, gas) do
    key = elem(atoms, atom_idx)  # atoms from closure, not shown here
    next([JSRuntime.get_property(obj, key) | stk], locs, frefs, insns, ip, gas)
  end

  # ── Calls ──
  defp step(:call, [argc], stk, locs, frefs, insns, ip, gas) do
    {args, [func | rest_stk]} = pop_n(stk, argc)
    case JSRuntime.call_function(func, args) do
      {:native_return, val} ->
        next([val | rest_stk], locs, frefs, insns, ip, gas)
      {:call_js, target_fref, new_locs} ->
        # Recursive call into another JS function — push return address
        # and re-enter the interpreter for the target
        call_js(target_fref, new_locs, rest_stk, insns, ip, gas, locs, frefs)
    end
  end

  # ... ~170 more opcode implementations
end
```

### 1.2 Stack Operations

The JS stack is an Elixir list. All operations are O(1) prepend/pop:

```elixir
# Push: [val | stack]
# Pop:   [top | rest] = stack
# Pop N: Enum.split(stack, n) → {popped, remaining}
# Peek:  hd(stack)
```

No heap allocation for the list cells themselves in the hot path — BEAM can
reuse list cells when they're provably unreachable (generational GC young-gen
collection is effectively free for short-lived data).

### 1.3 Locals

Locals (including args) are a tuple. Indexed by the `loc` argument:

```elixir
# get_loc(3) → elem(locs, 3)
# put_loc(3, val) → put_elem(locs, 3, val)
```

`elem/2` is a BEAM BIF that compiles to a single native instruction (array index).
`put_elem/3` allocates a new tuple but for small tuples (< 10 elements) this is
extremely cheap — just a memcpy of a few words.

### 1.4 Reduction Counting (BEAM Scheduler Cooperation)

BEAM preemptively reschedules processes that consume too many reductions.
The `gas` parameter decrements on every opcode. When it hits 0, the interpreter
yields and reschedules itself:

```elixir
@default_gas 2000  # ~2000 opcodes per time slice

def run(insns, locs, frefs, gas \\ @default_gas)

# Entry from caller:
def call_js(fref, args, stk, insns, ip, gas, ret_locs, ret_frefs) do
  fun = resolve_function(fref)
  locs = build_locals(fun, args)
  result = step(elem(fun.instructions, 0), stk, locs, fun.frefs, fun.instructions, 1, gas)
  handle_result(result, stk, insns, ip, ret_locs, ret_frefs)
end

defp handle_result({:return, val}, stk, insns, ip, locs, frefs) do
  # Push return value and continue in calling function
  next([val | stk], locs, frefs, insns, ip, @default_gas)
end

defp handle_result({:reduce, stk, locs, frefs, ip}, ...) do
  # Yield to BEAM scheduler, then resume
  send(self(), {:continue, stk, locs, frefs, ip})
  # Process will be rescheduled, picks up the message, continues
end
```

### 1.5 Process Loop

The interpreter runs inside a BEAM process that also handles messages
(`resolve_call`, `send_message`, etc. — same API as the current NIF-based runtime):

```elixir
defmodule QuickBEAM.BeamVM.Context do
  use GenServer

  def init(opts) do
    {:ok, %{bytecode: nil, functions: %{}, globals: %{}}}
  end

  def handle_call({:eval, code}, _from, state) do
    # 1. Compile JS → QJS bytecode (via existing NIF, one-time)
    {:ok, bytecode_binary} = QuickBEAM.compile_nif(code)
    # 2. Decode into instruction tuples
    {:ok, bytecode} = QuickBEAM.BeamVM.Bytecode.decode(bytecode_binary)
    # 3. Run the top-level function
    result = QuickBEAM.BeamVM.Interpreter.run(bytecode, 0, state)
    {:reply, {:ok, result}, state}
  end
end
```

### 1.6 Tests

- Use existing QuickBEAM test suite (1300+ tests) as correctness target
- Compile JS with existing QuickJS NIF, decode bytecode, run on BEAM interpreter
- Compare results byte-for-byte with NIF execution

**Estimated effort**: 3-5 weeks
**Lines of code**: ~4000

---

## Phase 2: JS Runtime Library

**Goal**: Correct JS semantics for all dynamic operations.

### 2.1 Value Representation

JS values as plain BEAM terms — no wrappers in the hot path:

```elixir
# JS values are BEAM terms. No tagged tuples for common types.
#
# JS number (integer) → BEAM integer
# JS number (float)   → BEAM float
# JS boolean          → BEAM boolean (true/false atoms)
# JS null/undefined   → BEAM nil
# JS string           → BEAM binary (UTF-8)
# JS symbol           → {:js_symbol, binary()}
# JS bigint           → {:js_bigint, integer()}
# JS object           → {:js_obj, ref()}  (ref into process-local store)
# JS array            → {:js_arr, ref(), length :: integer()}
# JS function         → {:js_fn, fn_ref()}
# JS undefined        → nil (same as null — differentiated by context)
```

For the interpreter's hot path, numbers/booleans/nil are unboxed BEAM immediates.
Zero overhead for integer arithmetic — the BEAM JIT compiles `a + b` to a single
native `add` instruction when both are small integers.

### 2.2 Object Store

Objects live in a process-local store. Two options, benchmarked:

**Option A: Process dictionary** (20x overhead vs direct — acceptable for property access
which is inherently dynamic):

```elixir
# Object = {shape_ref, proto_ref, {val1, val2, ...}}
# Stored in process dictionary keyed by ref()
# Shape describes which property names are at which tuple positions
#
# get_property: walk proto chain, find property in shape → elem(values, idx)
# set_property: check shape matches, put_elem(values, idx, val) or transition shape
```

**Option B: Dedicated ETS table** (85x overhead — too slow for hot path, but necessary
for shared objects across linked BEAM processes):

Use Option A for single-context objects, Option B only when crossing process boundaries.

### 2.3 Shapes (Hidden Classes)

V8-style hidden classes for fast property access:

```elixir
defmodule JSRuntime.Shape do
  # A shape is an immutable data structure:
  # {parent_shape | nil, property_name, index, next_shapes :: %{name => shape_ref}}
  #
  # Empty object → shape_0 (no properties)
  # obj.x = 1   → shape_1 = transition(shape_0, :x, 0)
  # obj.y = 2   → shape_2 = transition(shape_1, :y, 1)
  # obj.x = 3   → stays at shape_2 (property already exists)
  #
  # Objects with the same shape store values at the same tuple indices.
  # Shape transitions are cached — most property accesses are monomorphic.
end
```

Shapes are stored in the process dictionary (they're shared across objects,
not per-object). Transition lookups are O(1) via the `next_shapes` map.

### 2.4 Core Operations

```elixir
defmodule JSRuntime do
  # ── Type coercion (JS spec: ToPrimitive, ToNumber, ToString, ToBoolean) ──

  @spec add(term(), term()) :: term()
  # JS + : ToPrimitive both, if either is string → concat, else numeric add
  # Hot path optimization: if both are integers, just return a + b

  @spec strict_eq(term(), term()) :: boolean()
  # JS === : no coercion, type + value must match
  # nil !== nil is false in JS (null !== undefined), but both map to BEAM nil
  # → need special handling

  @spec abstract_eq(term(), term()) :: boolean()
  # JS == : complex coercion rules (the infamous == table)

  @spec get_property(term(), term()) :: term()
  # 1. ToObject(receiver)
  # 2. Walk prototype chain
  # 3. Check property descriptor (getter? throw if not writable?)
  # Hot path: if shape matches cached shape → direct elem access

  @spec set_property(term(), term(), term()) :: term()
  # Similar to get but modifies the object store entry

  @spec call_function(term(), [term()]) :: term()
  # JS function call with `this` = undefined (strict) or global (sloppy)

  @spec call_method(term(), term(), [term()]) :: term()
  # JS obj.method() with `this` = obj

  @spec typeof(term()) :: binary()
  @spec instanceof(term(), term()) :: boolean()
  @spec new_object() :: term()
  @spec new_array([term()]) :: term()
end
```

### 2.5 Built-in Objects

Minimum viable set:
- `Object` (keys, entries, assign, freeze, defineProperty)
- `Array` (push, pop, map, filter, reduce, slice, splice, indexOf)
- `Function` (bind, call, apply)
- `String` (charAt, substring, split, indexOf, trim, slice, includes)
- `Number` (parseInt, parseFloat, isNaN, isFinite)
- `Math` (floor, ceil, round, abs, min, max, random, PI)
- `JSON` (parse, stringify)
- `Promise` (then, catch, all, race, resolve, reject)
- `Error` (+ TypeError, RangeError, SyntaxError, with stack traces)
- `Date`, `RegExp`, `Map`, `Set`

**Estimated effort**: 6-8 weeks
**Lines of code**: ~3000 (core) + ~6000 (built-ins) = ~9000

---

## Phase 3: Integration + Testing

**Goal**: Replace the NIF thread with a BEAM process for the `:beam` mode,
run the full test suite.

### 3.1 Dual-Mode API

```elixir
defmodule QuickBEAM do
  def start(opts \\ []) do
    mode = Keyword.get(opts, :mode, :nif)
    # :nif   → current GenServer + NIF thread (unchanged)
    # :beam  → GenServer + BEAM interpreter (new)
    # :both  → side-by-side for testing/comparison
    case mode do
      :nif  -> QuickBEAM.Runtime.start_link(opts)
      :beam -> QuickBEAM.BeamVM.Context.start_link(opts)
    end
  end

  # Same public API regardless of mode
  def eval(server, code, opts \\ [])
  def call(server, name, args, opts \\ [])
  def compile(server, code)
  def define(server, name, value)
  def stop(server)
end
```

### 3.2 Compilation Pipeline

```elixir
# In :beam mode, eval/2 does:
def handle_call({:eval, code}, _from, state) do
  # 1. Use existing QuickJS NIF to compile JS → bytecode binary
  {:ok, bytecode_binary} = QuickBEAM.Native.compile(code)

  # 2. Decode bytecode into instruction tuples
  {:ok, bytecode} = QuickBEAM.BeamVM.Bytecode.decode(bytecode_binary)

  # 3. Execute on BEAM interpreter
  result = QuickBEAM.BeamVM.Interpreter.run(bytecode, state)

  {:reply, {:ok, result}, update_state(state, result)}
end
```

This reuses the existing QuickJS compiler (battle-tested, spec-compliant).
Only the *execution* moves to BEAM.

### 3.3 Test Strategy

```
1. Port existing test suite to run in :beam mode
2. Compare results between :nif and :beam for every test
3. Discrepancies → runtime library bugs
4. Target: 100% pass rate on existing 1300+ tests
```

### 3.4 async/await

JS `async/await` compiles to a state machine in QJS bytecode. The interpreter
handles the `await` opcode by suspending the function and resuming when the
promise resolves:

```elixir
defp step(:await, [], [promise | stk], locs, frefs, insns, ip, gas) do
  # Return a continuation that the process loop can resume later
  {:await, promise, stk, locs, frefs, insns, ip, gas}
end

# In the process loop:
defp handle_result({:await, promise, stk, locs, frefs, insns, ip, gas}, state) do
  # When promise resolves, send {:resolved, value} to self()
  # and store the continuation to resume
  Promise.on_resolve(promise, fn val ->
    send(self(), {:resume_await, val, stk, locs, frefs, insns, ip, gas})
  end)
  {:noreply, state}
end

def handle_info({:resume_await, val, stk, locs, frefs, insns, ip, gas}, state) do
  result = next([val | stk], locs, frefs, insns, ip, gas)
  handle_result(result, state)
end
```

This is more natural on BEAM than in the NIF — the process can actually suspend
and wait for a message, which is exactly how BEAM processes work natively.

**Estimated effort**: 3-4 weeks
**Lines of code**: ~2500

---

## Phase 4: Type Profiling (JIT Preparation)

**Goal**: Collect type information at runtime.

At this point we already have a working interpreter that beats QuickJS.
Phase 4-5 are optimizations that close the 4.4x gap to ~1x for hot code.

### 4.1 Inline Caches

```elixir
# Each call site (function_id, ip_offset) tracks:
# - observed argument types
# - observed object shapes (for property access)
# - observed call targets (for virtual calls)

# Stored in the process dictionary (one per interpreter process)
# Key: {function_id, ip_offset}
# Value: %IC{types: [...], hits: N, cached: ...}

defmodule QuickBEAM.BeamVM.IC do
  defstruct [:types, :hits, :cached_shape, :cached_target]

  # After 1000 hits with the same type signature → function is "hot"
  @hot_threshold 1000

  def record(ic, types) do
    %{ic | hits: ic.hits + 1, types: [types | ic.types |> Enum.take(9)]}
  end

  def hot?(%{hits: h}), do: h >= @hot_threshold
end
```

### 4.2 Type Feedback Summary

Before JIT compilation, summarize the ICs:

```elixir
%{
  {:add, 42} => %{types: [{:int, :int}], hit_rate: 1.0},
  {:get_field, 88} => %{shape: shape_ref_123, hit_rate: 0.99},
  {:call, 156} => %{target: fn_ref_456, hit_rate: 1.0},
}
```

**Estimated effort**: 2-3 weeks
**Lines of code**: ~1200

---

## Phase 5: JS Bytecode → BEAM Compiler (The JIT)

**Goal**: Compile hot JS functions to BEAM bytecode at runtime.

### 5.1 When Is It Worth It?

The interpreter with flat fn args is 4.4x slower than direct BEAM.
The JIT closes this to ~1x. For a function that takes 1000µs in the interpreter,
the JIT version takes ~230µs.

The JIT is worth it when:
- A function is called frequently (hot threshold met)
- The function has loops or is called in a loop
- Type profiles show monomorphic types (enables specialization)

The JIT is NOT worth it when:
- A function is called once (startup/cold code)
- The function is I/O bound (network, file, database)
- Types are megamorphic (no single type dominates — guard overhead > interpreter overhead)

### 5.2 Translation Pipeline

```
Pre-decoded instruction tuple
    │
    ▼
Stack depth analysis (static)
    │
    ▼
Basic blocks + control flow graph
    │
    ▼
BEAM Erlang Abstract Format
    │
    ▼
compile:forms(Forms, [binary]) → beam_bytes
    │
    ▼
code:load_binary(Module, '', beam_bytes)
```

Note: we target **Erlang Abstract Format** (not raw BEAM SSA).
`compile:forms/2` accepts the same format as the Erlang parser outputs,
which is much simpler to generate than raw SSA.

### 5.3 Example Translation

JS: `function add(a, b) { return a + b; }`

QJS bytecode: `get_arg0, get_arg1, add, return`

Type profile: 100% `(integer, integer)`

Generated Erlang Abstract Format:
```erlang
[
  {attribute, 1, module, js_fn_42_v1},
  {attribute, 1, export, [{func, 2}]},
  {function, 1, func, 2, [
    {clause, 1,
      [{var, 1, a}, {var, 1, b}],
      [[{call, 1, {remote, 1, {atom,1,erlang},{atom,1,is_integer}}, [{var,1,a}]},
         {call, 1, {remote, 1, {atom,1,erlang},{atom,1,is_integer}}, [{var,1,b}]}]],
      [{op, 1, '+', {var,1,a}, {var,1,b}}]},
    {clause, 1,
      [{var, 1, a}, {var, 1, b}],
      [],
      [{call, 1, {remote, 1, {atom,1,js_runtime},{atom,1,add}}, [{var,1,a}, {var,1,b}]}]}
  ]},
  {eof, 1}
]
```

This compiles to:
```
func(A, B) ->
  case is_integer(A) and is_integer(B) of
    true  -> A + B;        %% ← raw BEAM BIF, JIT-compiles to native add
    false -> js_runtime:add(A, B)   %% ← fallback to runtime
  end.
```

For a loop (`for (let i = 0; i < n; i++) sum += arr[i]`), the JIT generates
a tail-recursive BEAM function with type guards. After the BEAM JIT processes it,
it becomes a native loop — the same code as `DirectBEAM.sum` from our benchmarks.

### 5.4 Deoptimization

When a type guard fails, fall back to the interpreter:

```elixir
defp deopt(function_id, ip, stk, locs, frefs, bytecode) do
  # Reconstruct interpreter state from SSA values
  # Resume at the same bytecode position
  fun = Map.fetch!(bytecode.functions, function_id)
  QuickBEAM.BeamVM.Interpreter.next(stk, locs, frefs, fun.instructions, ip, @default_gas)
end
```

### 5.5 Module Lifecycle

```elixir
defmodule QuickBEAM.BeamVM.JIT do
  @compile_threshold 1000

  def maybe_compile(function_id, type_feedback, bytecode) do
    if hot?(type_feedback) and monomorphic?(type_feedback) do
      version = next_version(function_id)
      module = :"js_fn_#{function_id}_v#{version}"

      forms = translate(bytecode.functions[function_id], type_feedback)
      {:ok, ^module, beam_bytes} = :compile.forms(forms, [binary])
      :code.load_binary(module, '', beam_bytes)

      # Purge previous version
      purge_old(function_id, version)

      {:ok, {module, :func}}
    else
      :interpret
    end
  end
end
```

**Estimated effort**: 6-8 weeks
**Lines of code**: ~4000 (translator) + ~1000 (deopt/module mgmt) = ~5000

---

## Effort Summary

| Phase | Description | Effort | LOC | Performance |
|-------|------------|--------|-----|-------------|
| 0 | Bytecode loader + decoder | 2-3 wks | ~3,000 | — |
| 1 | Interpreter core | 3-5 wks | ~4,000 | ~4.4x vs direct BEAM, **7.5x faster than QJS** |
| 2 | JS runtime library | 6-8 wks | ~9,000 | enables all JS programs |
| 3 | Integration + testing | 3-4 wks | ~2,500 | 1300+ tests passing |
| 4 | Type profiling | 2-3 wks | ~1,200 | feeds JIT |
| 5 | JIT compiler | 6-8 wks | ~5,000 | ~1x vs direct BEAM |
| **Total** | | **22-31 wks** | **~25,000** | |

**The interpreter (Phase 0-2, ~11-16 weeks) already beats QuickJS by 7.5x.**
Phases 3-5 are correctness and further optimization.

---

## Key Risks

1. **JS coercion semantics**: `JSRuntime.add("1", 2)` must return `"12"` and
   `JSRuntime.add(1, 2)` must return `3`. The full ToPrimitive/ToNumber/ToString
   chain is complex. Test exhaustively against QuickJS.

2. **null vs undefined**: Both map to BEAM `nil`. In JS they're different
   (`null == undefined` is true, `null === undefined` is false).
   May need a sentinel: `{:js_undefined, nil}`.

3. **Prototype chain performance**: Property access through deep prototype chains
   is inherently O(chain_depth). Shape caching (inline caches) mitigates this for
   monomorphic access patterns.

4. **Closure mutability**: JS closures capture by reference. Use cells (boxed refs)
   that the closure environment shares. Works but adds indirection.

5. **Circular references**: BEAM GC doesn't handle cycles in process dictionary
   stored objects. Need periodic cycle detection or manual refcounting for the
   object store.

6. **Atom table growth**: Dynamic module names (`js_fn_42_v1`, `js_fn_42_v2`, ...)
   create atoms that are never garbage collected. Cap the version count and reuse
   module names.

## Not In Scope

- Full test262 compliance (target: common real-world JS)
- Web APIs (DOM, fetch) — stay in NIF runtime
- Source-level debugging
- WASM (already in QuickBEAM via separate path)
- Bytecode loader replaces QuickJS execution engine only; the compiler stays as-is
