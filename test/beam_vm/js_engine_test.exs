defmodule QuickBEAM.JSEngineTest.Helper do
  @moduledoc false

  def extract_function(source, func_name) do
    case :binary.match(source, "function #{func_name}(") do
      {start, _} ->
        rest = binary_part(source, start, byte_size(source) - start)

        case :binary.match(rest, "{") do
          {brace_pos, _} ->
            after_brace = binary_part(rest, brace_pos, byte_size(rest) - brace_pos)
            end_pos = find_end(after_brace, 0, 0)
            binary_part(rest, 0, brace_pos + end_pos)

          _ ->
            nil
        end

      :nomatch ->
        nil
    end
  end

  defp find_end(<<>>, _depth, pos), do: pos
  defp find_end(<<"{", rest::binary>>, depth, pos), do: find_end(rest, depth + 1, pos + 1)
  defp find_end(<<"}", _::binary>>, 1, pos), do: pos + 1
  defp find_end(<<"}", rest::binary>>, depth, pos), do: find_end(rest, depth - 1, pos + 1)

  defp find_end(<<"//", rest::binary>>, depth, pos) do
    case :binary.match(rest, "\n") do
      {nl, _} -> find_end(binary_part(rest, nl, byte_size(rest) - nl), depth, pos + 2 + nl)
      :nomatch -> pos + 2 + byte_size(rest)
    end
  end

  defp find_end(<<"\"", rest::binary>>, depth, pos), do: skip_string(rest, ?", depth, pos + 1)
  defp find_end(<<"'", rest::binary>>, depth, pos), do: skip_string(rest, ?', depth, pos + 1)
  defp find_end(<<"`", rest::binary>>, depth, pos), do: skip_string(rest, ?`, depth, pos + 1)
  defp find_end(<<_, rest::binary>>, depth, pos), do: find_end(rest, depth, pos + 1)

  defp skip_string(<<"\\", _, rest::binary>>, d, depth, pos), do: skip_string(rest, d, depth, pos + 2)

  defp skip_string(<<c, rest::binary>>, d, depth, pos) when c == d,
    do: find_end(rest, depth, pos + 1)

  defp skip_string(<<_, rest::binary>>, d, depth, pos), do: skip_string(rest, d, depth, pos + 1)
  defp skip_string(<<>>, _, _depth, pos), do: pos
end

defmodule QuickBEAM.JSEngineTest do
  use ExUnit.Case, async: true
  alias QuickBEAM.JSEngineTest.Helper

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

  @skip_builtin ~w(
    test_exception_source_pos test_function_source_pos test_exception_prepare_stack
    test_exception_stack_size_limit test_exception_capture_stack_trace
    test_exception_capture_stack_trace_filter test_cur_pc test_finalization_registry
    test_rope test_proxy_iter test_proxy_is_array test_eval2 test_weak_map test_weak_set
  )

  @skip_language ~w(
    test_reserved_names test_syntax test_parse_semicolon test_regexp_skip test_template_skip
  )

  setup_all do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  @js_dir Path.expand(".", __DIR__)

  for file <- ["test_builtin.js", "test_language.js"] do
    source = File.read!(Path.join(@js_dir, file))
    skip_list = if file == "test_builtin.js", do: @skip_builtin, else: @skip_language
    cleaned = String.replace(source, ~r/^import .*\n/m, "")

    func_names =
      Regex.scan(~r/^function (test_\w+)\(/m, cleaned)
      |> Enum.map(fn [_, name] -> name end)
      |> Enum.uniq()
      |> Enum.reject(fn name -> name in skip_list end)

    for func_name <- func_names do
      func_body = Helper.extract_function(cleaned, func_name)

      if func_body do
        @tag :js_engine
        test "#{file}: #{func_name}", %{rt: rt} do
          code = @assert_js <> unquote(func_body) <> "\n" <> unquote(func_name) <> "();"

          case QuickBEAM.eval(rt, code) do
            {:ok, _} -> :ok
            {:error, %QuickBEAM.JSError{message: msg}} -> flunk("JS: #{msg}")
            {:error, err} -> flunk("JS error: #{inspect(err)}")
          end
        end
      end
    end
  end
end
