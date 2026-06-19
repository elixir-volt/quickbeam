Mix.Task.run("app.start")
Code.require_file("support/common.exs", __DIR__)

alias QuickBEAM.VM.{BytecodeParser, Compiler, Heap, Interpreter}

iterations = Bench.Support.env_integer("COMPILER_PERF_ITERATIONS", 2000)
gas = 1_000_000_000

workload_specs = [
  {"arithmetic_loop", "(function(n){let s=0; for(let i=0;i<n;i++) s = s + i * 2; return s})",
   fn -> [100] end},
  {"array_sum", "(function(arr){let s=0; for(let i=0;i<arr.length;i++) s += arr[i]; return s})",
   fn -> [Heap.wrap(Enum.to_list(1..20))] end},
  {"object_property_loop",
   "(function(obj,n){let s=0; for(let i=0;i<n;i++) s += obj.x; return s})",
   fn -> [Heap.wrap(%{"x" => 3}), 100] end},
  {"closure_call",
   "(function(n){function inc(x){return x+1;} let s=0; for(let i=0;i<n;i++) s = inc(s); return s})",
   fn -> [100] end},
  {"class_method",
   "(function(n){class A { constructor(x){this.x=x;} m(){return this.x+1;} } let s=0; for(let i=0;i<n;i++) s += new A(i).m(); return s})",
   fn -> [30] end}
]

prepare_function = fn rt, source ->
  {:ok, bytecode} = QuickBEAM.compile(rt, source)
  {:ok, parsed} = BytecodeParser.decode(bytecode)
  fun = hd(for %QuickBEAM.VM.Function{} = f <- parsed.value.constants, do: f)

  store_atoms = fn store_atoms, %QuickBEAM.VM.Function{} = fun ->
    Heap.put_fn_atoms(fun, parsed.atoms)

    Enum.each(fun.constants, fn
      %QuickBEAM.VM.Function{} = inner -> store_atoms.(store_atoms, inner)
      _ -> :ok
    end)
  end

  store_atoms.(store_atoms, fun)
  fun
end

measure = fn fun -> Bench.Support.average_us(fun, iterations) end

Heap.reset()
{:ok, rt} = QuickBEAM.start(apis: false)
QuickBEAM.compile(rt, "0")

try do
  results =
    Enum.map(workload_specs, fn {name, source, args_fun} ->
      args = args_fun.()
      fun = prepare_function.(rt, source)

      {compile_us, {:ok, _compiled}} = :timer.tc(fn -> Compiler.compile(fun) end)
      {:ok, compiled_value} = Compiler.invoke(fun, args)
      interpreted_value = Interpreter.invoke(fun, args, gas)

      unless compiled_value === interpreted_value do
        raise "perf workload #{name} mismatch: compiled=#{inspect(compiled_value)} interpreted=#{inspect(interpreted_value)}"
      end

      compiler_us = measure.(fn -> {:ok, _} = Compiler.invoke(fun, args) end)
      interpreter_us = measure.(fn -> Interpreter.invoke(fun, args, gas) end)
      speedup = if compiler_us > 0, do: interpreter_us / compiler_us, else: 0.0

      %{
        name: name,
        compile_us: compile_us,
        compiler_us: compiler_us,
        interpreter_us: interpreter_us,
        speedup: speedup
      }
    end)

  for result <- results do
    IO.puts(
      "COMPILER_PERF workload=#{result.name} compile_us=#{Float.round(result.compile_us * 1.0, 2)} compiler_us=#{Float.round(result.compiler_us, 2)} interpreter_us=#{Float.round(result.interpreter_us, 2)} speedup=#{Float.round(result.speedup, 3)}"
    )
  end

  avg_speedup = Enum.sum(Enum.map(results, & &1.speedup)) / max(length(results), 1)
  avg_compiler_us = Enum.sum(Enum.map(results, & &1.compiler_us)) / max(length(results), 1)
  avg_interpreter_us = Enum.sum(Enum.map(results, & &1.interpreter_us)) / max(length(results), 1)

  Bench.Support.metrics(
    compiler_perf_workloads: length(results),
    compiler_avg_invoke_us: Float.round(avg_compiler_us, 3),
    interpreter_avg_invoke_us: Float.round(avg_interpreter_us, 3),
    compiler_avg_speedup: Float.round(avg_speedup, 3)
  )
after
  QuickBEAM.stop(rt)
end
