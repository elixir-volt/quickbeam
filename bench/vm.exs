# Benchmark: NIF (QuickJS native) vs BEAM compiler vs BEAM interpreter
# on Preact SSR — real-world workload.
#
# NIF uses QuickBEAM.call (GenServer round-trip).
# VM paths are in-process (no GenServer).

Code.require_file("support/preact_vm.exs", __DIR__)

source = Bench.PreactVM.bundle_source!()
props = Bench.PreactVM.props()

# ── BEAM VM (interpreter + compiler share the same decoded bytecode) ──

beam_run = fn invoke ->
  %{render_app: app, js_props: jp} = Bench.PreactVM.ensure_case!(source, props)
  invoke.(app, jp)
end

# ── NIF (QuickJS native via Zig NIF) ──

nif_source = String.replace(source, "(() => {", "var renderApp = (() => {", global: false)

{:ok, nif_rt} = QuickBEAM.start(apis: false)
{:ok, _} = QuickBEAM.eval(nif_rt, nif_source)
{:ok, _} = QuickBEAM.call(nif_rt, "renderApp", [props])

# ── run ──

Benchee.run(
  %{
    "NIF" => fn _ -> {:ok, _} = QuickBEAM.call(nif_rt, "renderApp", [props]) end,
    "VM.Compiler" => fn _ -> beam_run.(&Bench.PreactVM.run_compiler!/2) end,
    "VM.Interpreter" => fn _ -> beam_run.(&Bench.PreactVM.run_interpreter!/2) end
  },
  inputs: %{"preact_ssr" => nil},
  warmup: System.get_env("BENCH_WARMUP", "2") |> String.to_integer(),
  time: System.get_env("BENCH_TIME", "5") |> String.to_integer(),
  memory_time: System.get_env("BENCH_MEMORY_TIME", "2") |> String.to_integer(),
  print: [configuration: false]
)

QuickBEAM.stop(nif_rt)
