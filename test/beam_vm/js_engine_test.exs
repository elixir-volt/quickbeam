defmodule QuickBEAM.JSEngineTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.BeamVM.Heap

  # Skip list: tests that cannot work in beam mode
  # Source positions / stack traces: beam VM does not track JS source locations
  # eval/eval2: eval opcode not implemented in beam VM
  # array: defineProperty configurable:false + length truncation (C engine only)
  # cur_pc: spread destructuring defineProperty getter (C engine only)
  # rope: surrogate pair encoding differs in BEAM binaries
  @skip_builtin ~w(test_cur_pc test_eval test_eval2 test_array test_exception_source_pos test_function_source_pos test_exception_prepare_stack test_exception_stack_size_limit test_exception_capture_stack_trace test_rope)

  @skip_language ~w()

  setup do
    Heap.reset()
    {:ok, rt} = QuickBEAM.start()

    assert_js = strip_exports(File.read!("test/beam_vm/assert.js"))
    QuickBEAM.eval(rt, assert_js, mode: :beam)

    QuickBEAM.eval(
      rt,
      ~s|gc=function(){};os={platform:'elixir'};qjs={getStringKind:function(s){return s.length>256?1:0}}|,
      mode: :beam
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

    helper_fns =
      Enum.reject(fns, fn f ->
        (String.starts_with?(f.id.name, "test_") and f.params == []) or f.id.name == "test"
      end)

    helpers =
      Enum.map_join(helper_fns, "\n", &binary_part(source, &1.start, &1[:end] - &1.start))

    for %{id: %{name: func_name}} = func <- test_fns do
      func_body = binary_part(source, func.start, func[:end] - func.start)
      func_line = source |> binary_part(0, func.start) |> String.split("\n") |> length()

      @tag :js_engine
      test "#{file}: #{func_name}", %{rt: rt} do
        QuickBEAM.eval(rt, unquote(helpers), mode: :beam)

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
