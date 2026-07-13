defmodule QuickBEAM.VM.SvelteSSRTest do
  use ExUnit.Case, async: false

  @fixture "test/fixtures/vm/svelte_ssr.js"
  @eval_opts [
    profile: :ssr,
    max_steps: 20_000_000,
    memory_limit: 64_000_000,
    timeout: 5_000
  ]

  setup_all do
    assert {:ok, source} =
             QuickBEAM.JS.bundle_file(@fixture, format: :esm, minify: true)

    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: @fixture)
    {:ok, source: source, program: program}
  end

  test "renders pinned Svelte body and head after an asynchronous Beam.call", %{program: program} do
    assert {:ok, rendered} = eval(program, props("Featured", 1))

    assert rendered == %{
             "body" =>
               ~s(<main class="catalog"><h1>Featured</h1> <ul><!--[--><li class="available" data-id="1">Product 1: $12.99</li><!--]--></ul></main>),
             "head" => "<!--1vkpw87--><title>Featured</title><!---->"
           }
  end

  test "matches the vendored native QuickJS renderer", %{program: program, source: source} do
    props = props("Native parity", 2)
    handlers = %{"load_props" => fn [] -> props end}
    assert {:ok, runtime} = QuickBEAM.start(handlers: handlers)

    try do
      assert {:ok, %{}} = QuickBEAM.eval(runtime, source, timeout: 5_000)

      assert {:ok, native_rendered} =
               QuickBEAM.eval(runtime, "await globalThis.__quickbeamSSRResult", timeout: 5_000)

      assert {:ok, beam_rendered} = QuickBEAM.VM.eval(program, [handlers: handlers] ++ @eval_opts)
      assert beam_rendered == native_rendered
    after
      QuickBEAM.stop(runtime)
    end
  end

  test "shares one program across isolated concurrent Svelte renders", %{program: program} do
    tasks =
      for id <- 1..12 do
        Task.async(fn -> eval(program, props("Catalog #{id}", id)) end)
      end

    for {{:ok, rendered}, id} <- Enum.zip(Task.await_many(tasks, 10_000), 1..12) do
      assert rendered["body"] =~ "<h1>Catalog #{id}</h1>"
      assert rendered["body"] =~ ~s(data-id="#{id}")
      assert rendered["body"] =~ "Product #{id}"
      assert rendered["head"] == "<!--1vkpw87--><title>Catalog #{id}</title><!---->"
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
