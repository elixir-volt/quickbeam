defmodule QuickBEAM.JSEngineTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap

  @skip_builtin ~w()

  @skip_language ~w()

  setup do
    Heap.reset()
    {:ok, rt} = QuickBEAM.start()

    assert_js = strip_exports(File.read!("test/vm/assert.js"))
    QuickBEAM.eval(rt, assert_js, mode: :beam)

    qjs =
      Heap.wrap(%{
        "getStringKind" =>
          {:builtin, "getStringKind",
           fn
             [s | _], _ when is_binary(s) -> if byte_size(s) > 256, do: 1, else: 0
             _, _ -> 0
           end}
      })

    os = Heap.wrap(%{"platform" => "elixir"})

    Heap.put_persistent_globals(
      Map.merge(Heap.get_persistent_globals(), %{
        "gc" => {:builtin, "gc", fn _, _ -> :undefined end},
        "os" => os,
        "qjs" => qjs
      })
    )

    %{rt: rt}
  end

  @js_dir Path.expand(".", __DIR__)

  for file <- ["test_builtin.js", "test_language.js"] do
    source = File.read!(Path.join(@js_dir, file))
    skip_list = if file == "test_builtin.js", do: @skip_builtin, else: @skip_language

    {:ok, ast} = OXC.parse(source, file)

    fns = Enum.filter(ast.body, &(&1.type == :function_declaration))

    test_fns =
      fns
      |> Enum.filter(&(String.starts_with?(&1.id.name, "test_") and &1.params == []))
      |> Enum.reject(&(&1.id.name in skip_list))

    helper_fns = Enum.reject(fns, &(&1.id.name == "test"))

    for %{id: %{name: func_name}} = func <- test_fns do
      func_body = binary_part(source, func.start, func[:end] - func.start)
      func_line = source |> binary_part(0, func.start) |> String.split("\n") |> length()

      current_helpers =
        helper_fns
        |> Enum.reject(&(&1.id.name == func_name))
        |> Enum.map_join("\n", &binary_part(source, &1.start, &1[:end] - &1.start))

      @tag :js_engine
      test "#{file}: #{func_name}", %{rt: rt} do
        QuickBEAM.eval(rt, unquote(current_helpers), mode: :beam)

        padding = String.duplicate("\n", unquote(func_line) - 1)
        code = padding <> unquote(func_body) <> "\n" <> unquote(func_name) <> "();"

        case QuickBEAM.eval(rt, code, mode: :beam, filename: unquote(file)) do
          {:ok, _} -> :ok
          {:error, %QuickBEAM.JSError{message: msg}} -> flunk("JS: #{msg}")
          {:error, err} -> flunk("JS error: #{inspect(err)}")
        end
      end
    end
  end

  defp strip_exports(source) do
    {:ok, ast} = OXC.parse(source, "module.js")

    ast.body

    Enum.map_join(ast.body, "\n", fn
      %{type: :export_named_declaration, declaration: decl} ->
        binary_part(source, decl.start, decl[:end] - decl.start)

      node ->
        binary_part(source, node.start, node[:end] - node.start)
    end)
  end
end
