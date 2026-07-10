defmodule QuickBEAM.VM.PreactSSRTest do
  use ExUnit.Case, async: false

  @fixture "test/fixtures/vm/preact_ssr.js"

  setup_all do
    assert {:ok, source} = QuickBEAM.JS.bundle_file(@fixture, format: :esm, minify: false)
    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: @fixture)
    {:ok, source: source, program: program}
  end

  test "renders pinned Preact HTML after an asynchronous Beam.call", %{program: program} do
    props = props("Featured", 1)

    handler = fn [] ->
      Process.sleep(5)
      props
    end

    assert {:ok, html} =
             QuickBEAM.VM.eval(program,
               handlers: %{"load_props" => handler},
               max_steps: 20_000_000,
               timeout: 2_000
             )

    assert html ==
             ~s(<main class="catalog"><h1>Featured</h1><ul><li class="available" data-id="1">Product 1: $12.99</li></ul></main>)
  end

  test "matches the vendored native QuickJS renderer", %{program: program, source: source} do
    props = props("Native parity", 2)
    handlers = %{"load_props" => fn [] -> props end}

    assert {:ok, runtime} = QuickBEAM.start(handlers: handlers)

    try do
      assert {:ok, %{}} = QuickBEAM.eval(runtime, source, timeout: 2_000)

      assert {:ok, native_html} =
               QuickBEAM.eval(runtime, "await globalThis.__quickbeamSSRResult", timeout: 2_000)

      assert {:ok, beam_html} =
               QuickBEAM.VM.eval(program,
                 handlers: handlers,
                 max_steps: 20_000_000,
                 timeout: 2_000
               )

      assert beam_html == native_html
    after
      QuickBEAM.stop(runtime)
    end
  end

  test "shares one program across isolated concurrent renders", %{program: program} do
    tasks =
      for id <- 1..20 do
        Task.async(fn ->
          props = props("Catalog #{id}", id)

          QuickBEAM.VM.eval(program,
            handlers: %{"load_props" => fn [] -> props end},
            max_steps: 20_000_000,
            timeout: 2_000
          )
        end)
      end

    results = Task.await_many(tasks, 5_000)

    for {{:ok, html}, id} <- Enum.zip(results, 1..20) do
      assert html =~ "<h1>Catalog #{id}</h1>"
      assert html =~ ~s(data-id="#{id}")
      assert html =~ "Product #{id}"
    end
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
