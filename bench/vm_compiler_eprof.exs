Mix.Task.run("app.start")

alias QuickBEAM.VM.Compiler

iterations = String.to_integer(System.get_env("COMPILER_EPROF_ITERATIONS", "200"))
engine = System.get_env("COMPILER_EPROF_ENGINE", "compiler")
workload = System.get_env("COMPILER_EPROF_WORKLOAD", "object_property_loop")
phase = System.get_env("COMPILER_EPROF_PHASE", "execution")

sources = %{
  "arithmetic_loop" => "(function(n){let s=0;for(let i=0;i<n;i++)s=s+i*2;return s})(100)",
  "array_sum" =>
    "(function(arr){let s=0;for(let i=0;i<arr.length;i++)s+=arr[i];return s})([1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20])",
  "object_property_loop" =>
    "(function(obj,n){let s=0;for(let i=0;i<n;i++)s+=obj.x;return s})({x:3},100)"
}

source = if phase == "initialization", do: "0", else: Map.fetch!(sources, workload)
{:ok, compiler} = Compiler.start_link(capacity: 32)
{:ok, program} = QuickBEAM.VM.compile(source)

options =
  case engine do
    "compiler" ->
      [
        engine: :compiler,
        compiler_profile: :scalar_v1,
        isolation: :caller,
        max_steps: 1_000_000
      ]

    "interpreter" ->
      [isolation: :caller, max_steps: 1_000_000]

    invalid ->
      raise "unsupported COMPILER_EPROF_ENGINE=#{inspect(invalid)}"
  end

expected =
  case phase do
    "execution" -> QuickBEAM.VM.eval(program, options)
    "initialization" -> nil
    invalid -> raise "unsupported COMPILER_EPROF_PHASE=#{inspect(invalid)}"
  end

pool = Process.whereis(QuickBEAM.VM.Compiler.ModulePool)

tools_pattern = Path.join([to_string(:code.root_dir()), "lib", "tools-*", "ebin"])
[tools_ebin | _] = Path.wildcard(tools_pattern)
true = :code.add_patha(String.to_charlist(tools_ebin))
{:module, :eprof} = :code.ensure_loaded(:eprof)

:eprof.start()
:eprof.start_profiling([self(), pool])

profiled_iterations =
  case phase do
    "execution" ->
      Enum.each(1..iterations, fn _iteration ->
        ^expected = QuickBEAM.VM.eval(program, options)
      end)

      iterations

    "initialization" ->
      {:ok, _value} = QuickBEAM.VM.eval(program, options)
      1
  end

:eprof.stop_profiling()

profiled_workload = if phase == "initialization", do: "host_template", else: workload

IO.puts(
  "EPROF phase=#{phase} engine=#{engine} workload=#{profiled_workload} iterations=#{profiled_iterations}"
)

:eprof.analyze(:total)
:eprof.stop()
GenServer.stop(compiler)
