defmodule QuickBEAM.JSEngineTest do
  use ExUnit.Case, async: true

  @stubs_js """
  if (typeof gc === 'undefined') { var gc = function() {}; }
  if (typeof os === 'undefined') { var os = { platform: 'elixir' }; }
  if (typeof qjs === 'undefined') { var qjs = { getStringKind: function(s) { return s.length > 256 ? 1 : 0; } }; }
  """

  @skip_builtin ~w(
    test_exception_source_pos test_function_source_pos test_exception_prepare_stack
    test_exception_stack_size_limit test_exception_capture_stack_trace
    test_exception_capture_stack_trace_filter test_cur_pc test_finalization_registry
    test_rope test_proxy_iter test_proxy_is_array test_eval test_eval2 test_weak_map test_weak_set
    test_array
  )

  @skip_language ~w(
    test_reserved_names test_syntax test_parse_semicolon test_regexp_skip test_template_skip
  )

  setup do
    QuickBEAM.BeamVM.Heap.reset()
    {:ok, rt} = QuickBEAM.start()

    assert_js = strip_exports(File.read!("test/beam_vm/assert.js"))
    QuickBEAM.eval(rt, assert_js)

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
      |> Enum.filter(&(String.starts_with?(&1.id.name, "test_") and length(&1.params) == 0))
      |> Enum.reject(&(&1.id.name in skip_list))

    helper_fns =
      Enum.reject(fns, &(String.starts_with?(&1.id.name, "test_") and length(&1.params) == 0))

    helpers =
      helper_fns
      |> Enum.map(&binary_part(source, &1.start, &1[:end] - &1.start))
      |> Enum.join("\n")

    for %{id: %{name: func_name}} = func <- test_fns do
      func_body = binary_part(source, func.start, func[:end] - func.start)

      @tag :js_engine
      test "#{file}: #{func_name}", %{rt: rt} do
        code =
          @stubs_js <>
            unquote(helpers) <>
            "\n" <> unquote(func_body) <> "\n" <> unquote(func_name) <> "();"

        case QuickBEAM.eval(rt, code) do
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
    |> Enum.map(fn
      %{type: :export_named_declaration, declaration: decl} ->
        binary_part(source, decl.start, decl[:end] - decl.start)

      node ->
        binary_part(source, node.start, node[:end] - node.start)
    end)
    |> Enum.join("\n")
  end
end
