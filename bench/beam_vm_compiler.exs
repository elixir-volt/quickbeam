# Benchmark: BEAM bytecode interpreter vs compiled BEAM lowering
#
# Focuses on the internal BEAM VM execution path, not GenServer round-trip cost.
# Compares:
#   - Interpreter.invoke/3
#   - Compiler.invoke/2
# for the same decoded QuickJS bytecode function.

alias QuickBEAM.BeamVM.{Bytecode, Compiler, Heap, Interpreter}

{:ok, rt} = QuickBEAM.start()
Heap.reset()

cache_function_atoms = fn parsed, _cache_fun ->
  cache_fun =
    fn
      %Bytecode.Function{} = fun, atoms, recur ->
        Process.put({:qb_fn_atoms, fun.byte_code}, atoms)

        Enum.each(fun.constants, fn
          %Bytecode.Function{} = inner -> recur.(inner, atoms, recur)
          _ -> :ok
        end)

      _other, _atoms, _recur ->
        :ok
    end

  cache_fun.(parsed.value, parsed.atoms, cache_fun)
end

compile_case = fn code ->
  {:ok, bytecode} = QuickBEAM.compile(rt, code)
  {:ok, parsed} = Bytecode.decode(bytecode)
  cache_function_atoms.(parsed, cache_function_atoms)

  case for %Bytecode.Function{} = fun <- parsed.value.constants, do: fun do
    [fun | _] -> fun
    [] -> parsed.value
  end
end

cases = %{
  arithmetic_loop: %{
    fun: compile_case.("(function(n){ let s=0; for(let i=0;i<n;i++) s += i; return s })"),
    args: [1_000]
  },
  property_loop: %{
    fun:
      compile_case.(
        "(function(arr){ let s=0; for(let i=0;i<arr.length;i++) s += arr[i].x; return s })"
      ),
    args: [Heap.wrap(for i <- 1..100, do: %{"x" => i})]
  },
  recursion: %{
    fun: compile_case.("(function fib(n){ return n < 2 ? n : fib(n-1) + fib(n-2) })"),
    args: [18]
  },
  tail_recursion: %{
    fun: compile_case.("(function sum(n, acc){ return n ? sum(n - 1, acc + n) : acc })"),
    args: [300, 0]
  },
  local_calls: %{
    fun:
      compile_case.(
        "(function(n){ function f(x){ return x + 1 } let s = 0; for (let i = 0; i < n; i++) s += f(i); return s })"
      ),
    args: [400]
  },
  class_method: %{
    fun:
      compile_case.(
        "(function(v){ class Box { constructor(v){ this.v = v } get(){ return this.v } } return new Box(v).get() })"
      ),
    args: [123]
  }
}

inputs =
  Map.new(cases, fn {name, %{fun: fun, args: args}} ->
    {name, {fun, args}}
  end)

warmup = System.get_env("BENCH_WARMUP", "2") |> String.to_integer()
time = System.get_env("BENCH_TIME", "5") |> String.to_integer()
memory_time = System.get_env("BENCH_MEMORY_TIME", "2") |> String.to_integer()

Benchee.run(
  %{
    "Interpreter.invoke" => fn {fun, args} ->
      Interpreter.invoke(fun, args, 1_000_000)
    end,
    "Compiler.invoke" => fn {fun, args} ->
      {:ok, _result} = Compiler.invoke(fun, args)
    end
  },
  inputs: inputs,
  warmup: warmup,
  time: time,
  memory_time: memory_time,
  print: [configuration: false]
)

QuickBEAM.stop(rt)
