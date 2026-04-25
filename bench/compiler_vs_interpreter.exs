# Benchmark compiler vs interpreter on targeted JS patterns
# Run: MIX_ENV=bench mix run bench/compiler_vs_interpreter.exs

alias QuickBEAM.VM.{Compiler, Heap, Interpreter}

snippets = %{
  "numeric_loop" => """
    function bench() {
      let s = 0;
      for (let i = 0; i < 10000; i++) s += i;
      return s;
    }
  """,
  "object_field" => """
    function bench() {
      let o = {a: 1, b: 2, c: 3};
      let s = 0;
      for (let i = 0; i < 10000; i++) s += o.a + o.b + o.c;
      return s;
    }
  """,
  "function_call" => """
    function f(x) { return x + 1; }
    function bench() {
      let s = 0;
      for (let i = 0; i < 10000; i++) s += f(i);
      return s;
    }
  """,
  "closure" => """
    function make(n) { return function(x) { return x + n; }; }
    var add3 = make(3);
    function bench() {
      let s = 0;
      for (let i = 0; i < 10000; i++) s += add3(i);
      return s;
    }
  """,
  "array_loop" => """
    function bench() {
      let a = [1,2,3,4,5];
      let s = 0;
      for (let i = 0; i < 10000; i++) s += a[i % 5];
      return s;
    }
  """,
  "string_concat" => """
    function bench() {
      let s = '';
      for (let i = 0; i < 1000; i++) s += 'x';
      return s.length;
    }
  """
}

setup_snippet = fn source ->
  Heap.reset()
  {:ok, rt} = QuickBEAM.start(apis: false, mode: :beam)
  {:ok, _} = QuickBEAM.eval(rt, source, mode: :beam)
  bench_fun = Heap.get_persistent_globals() |> Map.fetch!("bench")
  {rt, bench_fun}
end

cases =
  Map.new(snippets, fn {name, source} ->
    {rt, bench_fun} = setup_snippet.(source)

    Enum.each(1..20, fn _ -> Compiler.invoke(bench_fun, []) end)

    {name, {rt, bench_fun}}
  end)

benchmarks =
  Enum.flat_map(cases, fn {name, {_rt, bench_fun}} ->
    [
      {"#{name}/compiler", fn -> {:ok, _} = Compiler.invoke(bench_fun, []) end},
      {"#{name}/interpreter", fn -> {:ok, _} = Interpreter.invoke(bench_fun, [], 1_000_000_000) end}
    ]
  end)
  |> Map.new()

Benchee.run(
  benchmarks,
  warmup: System.get_env("BENCH_WARMUP", "2") |> String.to_integer(),
  time: System.get_env("BENCH_TIME", "5") |> String.to_integer(),
  memory_time: System.get_env("BENCH_MEMORY_TIME", "2") |> String.to_integer(),
  print: [configuration: false]
)
