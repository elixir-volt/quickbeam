Mix.Task.run("app.start")

alias QuickBEAM.VM.Compiler

iterations =
  case Integer.parse(System.get_env("COMPILER_PERF_ITERATIONS", "500")) do
    {value, ""} when value > 0 -> value
    _invalid -> raise "COMPILER_PERF_ITERATIONS must be a positive integer"
  end

workloads = [
  {"arithmetic_loop", "(function(n){let s=0; for(let i=0;i<n;i++) s=s+i*2; return s})(100)"},
  {"branch_loop",
   "(function(n){let s=0; for(let i=0;i<n;i++){if((i&1)===0)s+=i;else s-=i} return s})(100)"},
  {"local_arithmetic",
   "(function(n){let a=1,b=2,c=3; for(let i=0;i<n;i++){a=b+c+i;b=a+c;c=a+b} return c})(100)"},
  {"array_sum",
   "(function(arr){let s=0;for(let i=0;i<arr.length;i++)s+=arr[i];return s})([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20])"},
  {"object_property_loop",
   "(function(obj,n){let s=0;for(let i=0;i<n;i++)s+=obj.x;return s})({x:3},100)"}
]

average_us = fn fun ->
  started = System.monotonic_time()
  Enum.each(1..iterations, fn _iteration -> fun.() end)
  elapsed = System.monotonic_time() - started
  System.convert_time_unit(elapsed, :native, :microsecond) / iterations
end

{:ok, compiler} = Compiler.start_link(capacity: 32)
{:ok, initialization_program} = QuickBEAM.VM.compile("0")

{runtime_init_us, {:ok, 0}} =
  :timer.tc(fn ->
    QuickBEAM.VM.eval(initialization_program, isolation: :caller, max_steps: 1_000_000)
  end)

IO.puts("COMPILER_PERF runtime_initialization_us=#{runtime_init_us} profile=core")

try do
  Enum.each(workloads, fn {name, source} ->
    {:ok, program} = QuickBEAM.VM.compile(source)
    interpreter_opts = [isolation: :caller, max_steps: 1_000_000]

    compiler_opts = [
      engine: :compiler,
      compiler_profile: :scalar_v1,
      isolation: :caller,
      max_steps: 1_000_000
    ]

    {cold_us, compiled_result} = :timer.tc(fn -> QuickBEAM.VM.eval(program, compiler_opts) end)
    interpreted_result = QuickBEAM.VM.eval(program, interpreter_opts)

    {:ok, _raw_value, raw_execution} =
      Compiler.start(program, compiler_profile: :scalar_v1, max_steps: 1_000_000)

    compiled_functions =
      Enum.count(raw_execution.compiler_context.decisions, fn {_id, decision} ->
        match?({:compile, _, _}, decision) or match?({:cached, _}, decision)
      end)

    if compiled_result != interpreted_result do
      raise "#{name} mismatch: compiler=#{inspect(compiled_result)} interpreter=#{inspect(interpreted_result)}"
    end

    compiler_us =
      average_us.(fn -> ^compiled_result = QuickBEAM.VM.eval(program, compiler_opts) end)

    interpreter_us =
      average_us.(fn -> ^interpreted_result = QuickBEAM.VM.eval(program, interpreter_opts) end)

    speedup = interpreter_us / compiler_us

    IO.puts(
      "COMPILER_PERF workload=#{name} compiled_functions=#{compiled_functions} " <>
        "cold_us=#{cold_us} " <>
        "compiler_us=#{Float.round(compiler_us, 2)} " <>
        "interpreter_us=#{Float.round(interpreter_us, 2)} speedup=#{Float.round(speedup, 3)}"
    )
  end)
after
  GenServer.stop(compiler)
end
