defmodule QuickBEAM.JSEngineTest do
  use ExUnit.Case, async: true

  @assert_js """
  function assert(actual, expected, message) {
    if (arguments.length === 1) expected = true;
    if (typeof actual === typeof expected) {
      if (actual === expected) {
        if (actual !== 0 || (1 / actual) === (1 / expected)) return;
      }
      if (typeof actual === 'number') {
        if (isNaN(actual) && isNaN(expected)) return;
      }
      if (typeof actual === 'object') {
        if (actual !== null && expected !== null
        &&  actual.constructor === expected.constructor
        &&  actual.toString() === expected.toString()) return;
      }
    }
    throw Error("assertion failed: got |" + actual + "|, expected |" + expected + "|" +
                (message ? " (" + message + ")" : ""));
  }
  function assertThrows(err, func) {
    var ex = false;
    try { func(); } catch(e) { ex = true; assert(e instanceof err); }
    assert(ex, true, "exception expected");
  }
  function assertArrayEquals(a, b) {
    if (!Array.isArray(a) || !Array.isArray(b)) return assert(false);
    assert(a.length, b.length);
    a.forEach(function(value, idx) { assert(b[idx], value); });
  }
  """

  @stubs_js """
  if (typeof gc === 'undefined') { var gc = function() {}; }
  if (typeof os === 'undefined') { var os = { platform: 'elixir' }; }
  if (typeof qjs === 'undefined') { var qjs = { getStringKind: function(s) { return s.length > 256 ? 1 : 0; } }; }
  """

  @skip_builtin ~w(
    test_exception_source_pos test_function_source_pos test_exception_prepare_stack
    test_exception_stack_size_limit test_exception_capture_stack_trace
    test_exception_capture_stack_trace_filter test_cur_pc test_finalization_registry
    test_rope test_proxy_iter test_proxy_is_array test_eval test_eval2 test_array test_weak_map test_weak_set
  )

  @skip_language ~w(
    test_reserved_names test_syntax test_parse_semicolon test_regexp_skip test_template_skip
  )

  setup do
    QuickBEAM.BeamVM.Heap.reset()
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  @js_dir Path.expand(".", __DIR__)

  for file <- ["test_builtin.js", "test_language.js"] do
    source = File.read!(Path.join(@js_dir, file))
    skip_list = if file == "test_builtin.js", do: @skip_builtin, else: @skip_language
    cleaned = String.replace(source, ~r/^import .*\n/m, "")

    {:ok, ast} = OXC.parse(cleaned, file)

    fns = Enum.filter(ast.body, &(&1.type == :function_declaration))

    test_fns =
      fns
      |> Enum.filter(&(String.starts_with?(&1.id.name, "test_") and length(&1.params) == 0))
      |> Enum.reject(&(&1.id.name in skip_list))

    helper_fns =
      Enum.reject(fns, &(String.starts_with?(&1.id.name, "test_") and length(&1.params) == 0))

    helpers =
      helper_fns
      |> Enum.map(&binary_part(cleaned, &1.start, &1[:end] - &1.start))
      |> Enum.join("\n")

    for %{id: %{name: func_name}} = func <- test_fns do
      func_body = binary_part(cleaned, func.start, func[:end] - func.start)

      @tag :js_engine
      test "#{file}: #{func_name}", %{rt: rt} do
        code =
          @stubs_js <>
            @assert_js <>
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
end
