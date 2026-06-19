defmodule QuickBEAM.VM.Stacktrace do
  @moduledoc "JS stack-trace capture and formatting: attaches `stack` to Error objects and supports `Error.prepareStackTrace`."

  import QuickBEAM.VM.Builtin, only: [object: 1]

  alias QuickBEAM.VM.Execution.Trace
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime
  alias QuickBEAM.VM.RuntimeState
  alias QuickBEAM.VM.SourcePosition

  @doc "Attaches a JavaScript stack string to an error object."
  def attach_stack({:obj, ref} = error_obj, filter_fun \\ nil) do
    stack = build_stack(error_obj, filter_fun)
    Heap.update_obj(ref, %{}, &Map.put(&1, "stack", stack))
    error_obj
  end

  @doc "Builds a JavaScript stack string from current VM frames."
  def build_stack(error_obj, filter_fun \\ nil) do
    frames = current_frames(filter_fun)

    case prepare_stack_trace() do
      fun when fun != nil and fun != :undefined ->
        Runtime.call_callback(fun, [error_obj, Heap.wrap(Enum.map(frames, &callsite_object/1))])

      _ ->
        format_stack(frames)
    end
  end

  @doc "Returns the current VM stacktrace frames."
  def current_frames(filter_fun \\ nil) do
    frames = Trace.get_frames()
    limit = stack_trace_limit()

    frames
    |> maybe_drop_until(filter_fun)
    |> Enum.take(limit)
    |> Enum.map(&frame_info/1)
  end

  defp maybe_drop_until(frames, nil), do: frames

  defp maybe_drop_until(frames, filter_fun) do
    case Enum.split_while(frames, fn %{fun: fun} -> fun !== filter_fun end) do
      {_, []} -> frames
      {before, [_matched | rest]} when before == [] -> rest
      {_before, [_matched | rest]} -> rest
    end
  end

  defp frame_info(%{fun: fun_term, pc: pc}) do
    fun = bytecode_fun(fun_term)
    {line, col} = SourcePosition.source_position(fun, pc)

    %{
      function: fun_term,
      function_name: function_name(fun),
      file_name: fun.filename || "",
      line_number: line,
      column_number: col
    }
  end

  defp bytecode_fun({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: fun
  defp bytecode_fun(%QuickBEAM.VM.Function{} = fun), do: fun

  defp function_name(%QuickBEAM.VM.Function{name: name}) when is_binary(name) and name != "",
    do: name

  defp function_name(_), do: nil

  defp prepare_stack_trace, do: error_static("prepareStackTrace", :undefined)

  defp stack_trace_limit do
    case error_static("stackTraceLimit", 10) do
      n when is_integer(n) and n >= 0 -> n
      n when is_float(n) and n >= 0 -> trunc(n)
      _ -> 10
    end
  end

  defp error_static(key, default) do
    case RuntimeState.current() do
      %{globals: globals} ->
        case Map.get(globals, "Error") do
          {:builtin, _, _} = ctor -> Map.get(Heap.get_ctor_statics(ctor), key, default)
          _ -> default
        end

      _ ->
        default
    end
  end

  defp format_stack(frames) do
    Enum.map_join(frames, "\n", fn frame ->
      suffix =
        "#{format_function_name(frame.file_name)}:#{frame.line_number}:#{frame.column_number}"

      case frame.function_name do
        nil -> "    at #{suffix}"
        name -> "    at #{format_function_name(name)} (#{suffix})"
      end
    end)
  end

  defp format_function_name({:predefined, _} = name),
    do: QuickBEAM.VM.Names.resolve_display_name(name)

  defp format_function_name(name), do: to_string(name)

  defp callsite_object(frame) do
    object do
      method "getFileName" do
        frame.file_name
      end

      method "getFunction" do
        frame.function
      end

      method "getFunctionName" do
        frame.function_name || :undefined
      end

      method "getLineNumber" do
        frame.line_number
      end

      method "getColumnNumber" do
        frame.column_number
      end

      method "isNative" do
        false
      end
    end
  end
end
