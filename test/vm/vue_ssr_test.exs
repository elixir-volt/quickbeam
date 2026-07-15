defmodule QuickBEAM.VM.VueSSRTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Compiler
  alias QuickBEAM.VM.Compiler.ModulePool

  @fixture "test/fixtures/vm/vue_ssr.js"
  @bundle_opts [
    format: :esm,
    minify: true,
    define: %{
      "__VUE_OPTIONS_API__" => "true",
      "__VUE_PROD_DEVTOOLS__" => "false",
      "__VUE_PROD_HYDRATION_MISMATCH_DETAILS__" => "false",
      "process.env.NODE_ENV" => ~s("production")
    }
  ]
  @eval_opts [
    profile: :ssr,
    max_steps: 50_000_000,
    memory_limit: 256_000_000,
    timeout: 5_000
  ]

  setup_all do
    start_supervised!({Compiler, capacity: 8})
    assert {:ok, source} = QuickBEAM.JS.bundle_file(@fixture, @bundle_opts)
    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: @fixture)
    {:ok, source: source, program: program}
  end

  test "renders pinned Vue HTML after an asynchronous Beam.call", %{program: program} do
    assert {:ok, html} = eval(program, props("Featured", 1))

    assert html ==
             ~s(<main class="catalog"><h1>Featured</h1><ul><li class="available" data-id="1">Product 1: $12.99</li></ul></main>)
  end

  test "matches the vendored native QuickJS renderer", %{program: program, source: source} do
    props = props("Native parity", 2)
    handlers = %{"load_props" => fn [] -> props end}
    assert {:ok, runtime} = QuickBEAM.start(handlers: handlers)

    try do
      assert {:ok, %{}} = QuickBEAM.eval(runtime, source, timeout: 5_000)

      assert {:ok, native_html} =
               QuickBEAM.eval(runtime, "await globalThis.__quickbeamSSRResult", timeout: 5_000)

      assert {:ok, beam_html} = QuickBEAM.VM.eval(program, [handlers: handlers] ++ @eval_opts)

      assert {:ok, compiler_html} =
               QuickBEAM.VM.eval(program, [engine: :compiler, handlers: handlers] ++ @eval_opts)

      assert beam_html == native_html
      assert compiler_html == native_html
      stats = ModulePool.stats(ModulePool)
      assert stats.counts.ready >= 1
      assert stats.skips >= 1
    after
      QuickBEAM.stop(runtime)
    end
  end

  test "shares one program across isolated concurrent Vue renders", %{program: program} do
    tasks =
      for id <- 1..8 do
        Task.async(fn -> eval(program, props("Catalog #{id}", id)) end)
      end

    for {{:ok, html}, id} <- Enum.zip(Task.await_many(tasks, 10_000), 1..8) do
      assert html =~ "<h1>Catalog #{id}</h1>"
      assert html =~ ~s(data-id="#{id}")
      assert html =~ "Product #{id}"
    end
  end

  defp eval(program, props) do
    handler = fn [] ->
      Process.sleep(5)
      props
    end

    QuickBEAM.VM.eval(program, [handlers: %{"load_props" => handler}] ++ @eval_opts)
  end

  defp props(title, id) do
    %{
      "title" => title,
      "products" => [
        %{
          "id" => id,
          "name" => "Product #{id}",
          "inStock" => rem(id, 2) == 1,
          "priceCents" => 1_299 + (id - 1) * 100
        }
      ]
    }
  end
end
