Code.require_file("support/preact_vm.exs", __DIR__)

source = Bench.PreactVM.bundle_source!()
props = Bench.PreactVM.props()
{:ok, rt} = Bench.PreactVM.start_runtime()

%{parsed: parsed, render_app: render_app, render_fun: render_fun, js_props: js_props} =
  Bench.PreactVM.build_case!(rt, source, props)

Bench.PreactVM.warmup(render_app, js_props, 30)

render_app_qjs = Bench.PreactVM.find_vm_function(parsed.value, &(&1.name == "renderApp"))
beam = Bench.PreactVM.beam_disasm!(render_fun)

File.write!(
  "/tmp/preact_vm_render_app_quickjs.txt",
  inspect(render_app_qjs, pretty: true, limit: :infinity)
)

File.write!(
  "/tmp/preact_vm_render_app_opcodes.txt",
  inspect(Bench.PreactVM.opcode_histogram(render_app_qjs), pretty: true, limit: :infinity)
)

File.write!("/tmp/preact_vm_beam_disasm.txt", inspect(beam, pretty: true, limit: :infinity))

iterations = System.get_env("PROFILE_ITERS", "200") |> String.to_integer()

case :code.which(:eprof) do
  path when is_list(path) ->
    :eprof.start()

    :eprof.profile(fn ->
      Enum.each(1..iterations, fn _ ->
        Bench.PreactVM.run_compiler!(render_app, js_props)
      end)
    end)

    :eprof.analyze([:total])

  :non_existing ->
    {elapsed_us, _} =
      :timer.tc(fn ->
        Enum.each(1..iterations, fn _ ->
          Bench.PreactVM.run_compiler!(render_app, js_props)
        end)
      end)

    File.write!(
      "/tmp/preact_vm_profile_summary.txt",
      "eprof unavailable on this Erlang installation\niterations=#{iterations}\nelapsed_us=#{elapsed_us}\n"
    )
end

QuickBEAM.stop(rt)
