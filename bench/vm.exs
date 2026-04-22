# Benchmark: BEAM compiler vs BEAM interpreter on Preact SSR.
#
# NIF (QuickJS native) is excluded: a GC bug in QuickJS-NG panics
# when the bundled Preact code is called repeatedly via call_function
# (null pointer in gc_scan_incref_child → list_del).

Code.require_file("support/preact_vm.exs", __DIR__)

source = Bench.PreactVM.bundle_source!()
props = Bench.PreactVM.props()

beam_run = fn invoke ->
  %{render_app: app, js_props: jp} = Bench.PreactVM.ensure_case!(source, props)
  invoke.(app, jp)
end

Benchee.run(
  %{
    "VM.Compiler" => fn _ -> beam_run.(&Bench.PreactVM.run_compiler!/2) end,
    "VM.Interpreter" => fn _ -> beam_run.(&Bench.PreactVM.run_interpreter!/2) end
  },
  inputs: %{"preact_ssr" => nil},
  warmup: System.get_env("BENCH_WARMUP", "2") |> String.to_integer(),
  time: System.get_env("BENCH_TIME", "5") |> String.to_integer(),
  memory_time: System.get_env("BENCH_MEMORY_TIME", "2") |> String.to_integer(),
  print: [configuration: false]
)
