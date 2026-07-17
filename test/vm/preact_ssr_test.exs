defmodule QuickBEAM.VM.PreactSSRTest do
  use ExUnit.Case, async: false

  @fixture "test/fixtures/vm/preact_ssr.js"

  setup_all do
    assert {:ok, source} = QuickBEAM.JS.bundle_file(@fixture, format: :esm, minify: false)
    assert {:ok, program} = QuickBEAM.VM.compile(source, filename: @fixture)
    call_source = call_source!()
    assert {:ok, call_program} = QuickBEAM.VM.compile(call_source, filename: @fixture)
    {:ok, source: source, program: program, call_source: call_source, call_program: call_program}
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

  test "calls the same named async renderer shape as the native runtime", %{
    call_program: call_program,
    call_source: call_source
  } do
    props = props("Call parity", 3)
    handlers = %{"load_props" => fn [] -> props end}

    assert {:ok, runtime} = QuickBEAM.start(handlers: handlers, apis: false)

    try do
      assert {:ok, %{}} = QuickBEAM.eval(runtime, call_source, timeout: 2_000)
      assert {:ok, native_html} = QuickBEAM.call(runtime, "__quickbeamRender", [], timeout: 2_000)

      assert {:ok, beam_html} =
               QuickBEAM.VM.call(call_program, "__quickbeamRender", [],
                 profile: :ssr,
                 handlers: handlers,
                 max_steps: 20_000_000,
                 timeout: 2_000
               )

      assert beam_html == native_html
      assert beam_html =~ "<h1>Call parity</h1>"
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

  defp call_source! do
    source = File.read!(@fixture)

    call_source =
      source
      |> String.replace(
        "globalThis.__quickbeamSSRResult = (async function",
        "globalThis.__quickbeamRender = async function"
      )
      |> String.replace("})();\n\nglobalThis.__quickbeamSSRResult;", "};")

    refute call_source == source

    temporary =
      Path.join(Path.dirname(@fixture), ".call-#{System.unique_integer([:positive])}.js")

    File.write!(temporary, call_source)

    try do
      assert {:ok, bundled} = QuickBEAM.JS.bundle_file(temporary, format: :esm, minify: false)
      bundled
    after
      File.rm!(temporary)
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
