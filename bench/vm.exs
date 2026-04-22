# Benchmark: NIF (QuickJS native) vs BEAM compiler vs BEAM interpreter
#
# Micro-benchmarks compare all three paths.
# Preact SSR compares BEAM compiler vs interpreter (NIF excluded —
# the bundled Preact source triggers a QuickJS GC bug via call_function).

Code.require_file("support/preact_vm.exs", __DIR__)

alias QuickBEAM.VM.{Bytecode, Compiler, Heap, Interpreter}

defmodule Bench.NIF do
  def eval!(resource, code) do
    ref = QuickBEAM.Native.eval(resource, code, 0, "")

    receive do
      {^ref, {:ok, _}} -> :ok
      {^ref, {:error, e}} -> raise "NIF eval error: #{inspect(e)}"
    after
      5_000 -> raise "NIF eval timeout"
    end
  end

  def call!(resource, name, args) do
    ref = QuickBEAM.Native.call_function(resource, name, args, 0)

    receive do
      {^ref, {:ok, v}} -> v
      {^ref, {:error, e}} -> throw({:nif_error, e})
    after
      5_000 -> throw(:nif_timeout)
    end
  end
end

# ── BEAM VM setup ──

{:ok, beam_rt} = QuickBEAM.start(apis: false, mode: :beam)
Heap.reset()

cache_atoms = fn parsed ->
  recur = fn
    %Bytecode.Function{} = fun, atoms, r ->
      Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

      Enum.each(fun.constants, fn
        %Bytecode.Function{} = inner -> r.(inner, atoms, r)
        _ -> :ok
      end)

    _, _, _ ->
      :ok
  end

  recur.(parsed.value, parsed.atoms, recur)
end

compile_fn = fn code ->
  {:ok, bc} = QuickBEAM.compile(beam_rt, code)
  {:ok, parsed} = Bytecode.decode(bc)
  cache_atoms.(parsed)

  case for(%Bytecode.Function{} = f <- parsed.value.constants, do: f) do
    [f | _] -> f
    [] -> parsed.value
  end
end

# ── NIF setup ──

{:ok, nif_rt} = QuickBEAM.start(apis: false)
nif_res = QuickBEAM.Runtime.resource(nif_rt)

# ── cases ──

cases = [
  {:arithmetic_loop,
   "(function(n){ let s=0; for(let i=0;i<n;i++) s += i; return s })",
   "function arithmetic_loop(n){ let s=0; for(let i=0;i<n;i++) s += i; return s }",
   [1_000]},
  {:property_loop,
   "(function(arr){ let s=0; for(let i=0;i<arr.length;i++) s += arr[i].x; return s })",
   nil,
   [Heap.wrap(for i <- 1..100, do: %{"x" => i})]},
  {:recursion,
   "(function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2) })",
   "function recursion(n){ return n < 2 ? n : recursion(n-1) + recursion(n-2) }",
   [18]},
  {:tail_recursion,
   "(function sum(n, acc){ return n ? sum(n - 1, acc + n) : acc })",
   nil,
   [300, 0]},
  {:local_calls,
   "(function(n){ function f(x){ return x + 1 } let s = 0; for (let i = 0; i < n; i++) s += f(i); return s })",
   "function local_calls(n){ function f(x){ return x + 1 } let s = 0; for (let i = 0; i < n; i++) s += f(i); return s }",
   [400]},
  {:class_method,
   "(function(v){ class Box { constructor(v){ this.v = v } get(){ return this.v } } return new Box(v).get() })",
   "function class_method(v){ class Box { constructor(v){ this.v = v } get(){ return this.v } } return new Box(v).get() }",
   [123]}
]

beam_inputs = %{}
nif_inputs = %{}

{beam_inputs, nif_inputs} =
  Enum.reduce(cases, {%{}, %{}}, fn {name, iife, nif_src, args}, {beam, nif} ->
    fun = compile_fn.(iife)
    beam = Map.put(beam, name, {fun, args})

    nif =
      if nif_src do
        Bench.NIF.eval!(nif_res, nif_src)
        Map.put(nif, name, {Atom.to_string(name), args})
      else
        nif
      end

    {beam, nif}
  end)

# ── Preact SSR ──

preact_source = Bench.PreactVM.bundle_source!()
preact_props = Bench.PreactVM.props()

preact_beam = fn invoke ->
  %{render_app: app, js_props: jp} = Bench.PreactVM.ensure_case!(preact_source, preact_props)
  invoke.(app, jp)
end

# ── run ──

warmup = System.get_env("BENCH_WARMUP", "2") |> String.to_integer()
time = System.get_env("BENCH_TIME", "5") |> String.to_integer()
memory_time = System.get_env("BENCH_MEMORY_TIME", "2") |> String.to_integer()

IO.puts("\n━━━ Micro-benchmarks (Interpreter vs Compiler) ━━━\n")

Benchee.run(
  %{
    "Interpreter" => fn {fun, args} -> Interpreter.invoke(fun, args, 1_000_000) end,
    "Compiler" => fn {fun, args} -> {:ok, _} = Compiler.invoke(fun, args) end
  },
  inputs: beam_inputs,
  warmup: warmup,
  time: time,
  memory_time: memory_time,
  print: [configuration: false]
)

IO.puts("\n━━━ Micro-benchmarks (NIF) ━━━\n")

Benchee.run(
  %{
    "Interpreter" => fn {_, {fun, args}} -> Interpreter.invoke(fun, args, 1_000_000) end,
    "Compiler" => fn {_, {fun, args}} -> {:ok, _} = Compiler.invoke(fun, args) end,
    "NIF" => fn {{nif_name, args}, _} -> Bench.NIF.call!(nif_res, nif_name, args) end
  },
  inputs:
    Map.new(nif_inputs, fn {name, nif_val} -> {name, {nif_val, beam_inputs[name]}} end),
  warmup: warmup,
  time: time,
  memory_time: memory_time,
  print: [configuration: false]
)

IO.puts("\n━━━ Preact SSR ━━━\n")

Benchee.run(
  %{
    "VM.Interpreter" => fn _ -> preact_beam.(&Bench.PreactVM.run_interpreter!/2) end,
    "VM.Compiler" => fn _ -> preact_beam.(&Bench.PreactVM.run_compiler!/2) end
  },
  inputs: %{"preact_ssr" => nil},
  warmup: warmup,
  time: time,
  memory_time: memory_time,
  print: [configuration: false]
)

QuickBEAM.stop(beam_rt)
QuickBEAM.stop(nif_rt)
