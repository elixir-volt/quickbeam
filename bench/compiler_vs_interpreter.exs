# Benchmark compiler vs interpreter on targeted JS patterns
# Run: MIX_ENV=bench mix run bench/compiler_vs_interpreter.exs

alias QuickBEAM.VM.{Compiler, Heap, Interpreter}

snippets = [
  {"numeric_loop", "let s = 0; for (let i = 0; i < 10000; i++) s += i; s;"},
  {"object_field", "let o = {a: 1, b: 2, c: 3}; let s = 0; for (let i = 0; i < 10000; i++) s += o.a + o.b + o.c; s;"},
  {"function_call",
   "function f(x) { return x + 1; } let s = 0; for (let i = 0; i < 10000; i++) s += f(i); s;"},
  {"closure",
   "function make(n) { return function(x) { return x + n; }; } var add3 = make(3); let s = 0; for (let i = 0; i < 10000; i++) s += add3(i); s;"},
  {"array_loop",
   "let a = [1,2,3,4,5]; let s = 0; for (let i = 0; i < 10000; i++) s += a[i % 5]; s;"},
  {"string_concat", "let s = ''; for (let i = 0; i < 1000; i++) s += 'x'; s.length;"}
]

Heap.reset()
{:ok, rt} = QuickBEAM.start(apis: false, mode: :beam)

cases =
  for {name, source} <- snippets do

    # Wrap in a function for repeatable invocation
    wrapped = "(function() { #{source} })"
    {:ok, bench_fun} = QuickBEAM.eval(rt, wrapped, mode: :beam)

    # Warm up
    Enum.each(1..5, fn _ -> Compiler.invoke(bench_fun, []) end)

    {name, bench_fun}
  end

benchmarks =
  Enum.flat_map(cases, fn {name, bench_fun} ->
    [
      {"#{name}/compiler", fn -> {:ok, _} = Compiler.invoke(bench_fun, []) end},
      {"#{name}/interpreter", fn -> Interpreter.invoke(bench_fun, [], 1_000_000_000) end}
    ]
  end)
  |> Map.new()

Benchee.run(
  benchmarks,
  warmup: String.to_integer(System.get_env("BENCH_WARMUP", "2")),
  time: String.to_integer(System.get_env("BENCH_TIME", "5")),
  print: [configuration: false]
)
