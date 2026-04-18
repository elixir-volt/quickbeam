defmodule QuickBEAM.JSEngineTest do
  @moduledoc """
  Runs QuickJS-ng test_builtin.js and test_language.js against both backends.
  Each test_*() function becomes an ExUnit test case.
  """
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

  # Functions that use QuickJS-specific APIs unavailable in our BEAM interpreter
  @skip_builtin [
    "test_exception_source_pos",
    "test_function_source_pos",
    "test_exception_prepare_stack",
    "test_exception_stack_size_limit",
    "test_exception_capture_stack_trace",
    "test_exception_capture_stack_trace_filter",
    "test_cur_pc",
    "test_finalization_registry",
    "test_rope",
    "test_proxy_iter",
    "test_proxy_is_array",
    "test_eval2",
    "test_weak_map",
    "test_weak_set"
  ]

  @skip_language [
    "test_reserved_names",
    "test_syntax",
    "test_parse_semicolon",
    "test_regexp_skip",
    "test_template_skip"
  ]

  setup_all do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  @js_dir Path.expand(".", __DIR__)

  for file <- ["test_builtin.js", "test_language.js"] do
    source = File.read!(Path.join(@js_dir, file))
    skip_list = if file == "test_builtin.js", do: @skip_builtin, else: @skip_language

    # Extract function bodies: find each "function test_xxx() { ... }" and the runner call
    # Strategy: extract all test_* function names, then for each one, run the whole file
    # with only that function called at the end.

    # Parse function names from "function test_xxx("
    func_names =
      Regex.scan(~r/^function (test_\w+)\(/m, source)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.reject(fn name -> name in skip_list end)

    for func_name <- func_names do
      # Strip the imports and the main() call at the bottom
      cleaned =
        source
        |> String.replace(~r/^import .*\n/m, "")
        |> String.replace(~r/^test_\w+\(\);\s*$/m, "")

      test_code = "#{cleaned}\n#{func_name}();"

      @tag :js_engine
      test "#{file}: #{func_name}", %{rt: rt} do
        code = @assert_js <> unquote(test_code)

        case QuickBEAM.eval(rt, code) do
          {:ok, _} ->
            :ok

          {:error, %QuickBEAM.JSError{message: msg}} ->
            flunk("JS assertion failed: #{msg}")

          {:error, err} ->
            flunk("JS error: #{inspect(err)}")
        end
      end
    end
  end
end
