Code.require_file("support/preact_vm.exs", __DIR__)

source = Bench.PreactVM.bundle_source!()
props = Bench.PreactVM.props()

run = fn invoke ->
  %{render_app: render_app, js_props: js_props} = Bench.PreactVM.ensure_case!(source, props)
  invoke.(render_app, js_props)
end

Benchee.run(
  %{
    "VM.Interpreter.invoke" => fn ->
      run.(&Bench.PreactVM.run_interpreter!/2)
    end,
    "VM.Compiler.invoke" => fn ->
      run.(&Bench.PreactVM.run_compiler!/2)
    end
  },
  warmup: System.get_env("BENCH_WARMUP", "2") |> String.to_integer(),
  time: System.get_env("BENCH_TIME", "5") |> String.to_integer(),
  memory_time: System.get_env("BENCH_MEMORY_TIME", "2") |> String.to_integer(),
  print: [configuration: false]
)
