defmodule QuickBEAM.BeamVM.Stacktrace do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap}
  alias QuickBEAM.BeamVM.Runtime

  def attach_stack({:obj, ref} = error_obj, filter_fun \\ nil) do
    stack = build_stack(error_obj, filter_fun)
    Heap.update_obj(ref, %{}, &Map.put(&1, "stack", stack))
    error_obj
  end

  def build_stack(error_obj, filter_fun \\ nil) do
    frames = current_frames(filter_fun)

    case prepare_stack_trace() do
      fun when fun != nil and fun != :undefined ->
        Runtime.call_callback(fun, [error_obj, Heap.wrap(Enum.map(frames, &callsite_object/1))])

      _ ->
        format_stack(frames)
    end
  end

  def current_frames(filter_fun \\ nil) do
    frames = Process.get(:qb_active_frames, [])
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
    {line, col} = Bytecode.source_position(fun, pc)

    %{
      function: fun_term,
      function_name: function_name(fun),
      file_name: fun.filename || "",
      line_number: line,
      column_number: col
    }
  end

  defp bytecode_fun({:closure, _, %Bytecode.Function{} = fun}), do: fun
  defp bytecode_fun(%Bytecode.Function{} = fun), do: fun

  defp function_name(%Bytecode.Function{name: name}) when is_binary(name) and name != "", do: name
  defp function_name(_), do: nil

  defp prepare_stack_trace do
    case Heap.get_ctx() do
      %{globals: globals} ->
        case Map.get(globals, "Error") do
          {:builtin, _, _} = ctor -> Map.get(Heap.get_ctor_statics(ctor), "prepareStackTrace", :undefined)
          _ -> :undefined
        end

      _ ->
        :undefined
    end
  end

  defp stack_trace_limit do
    case Heap.get_ctx() do
      %{globals: globals} ->
        case Map.get(globals, "Error") do
          {:builtin, _, _} = ctor ->
            case Map.get(Heap.get_ctor_statics(ctor), "stackTraceLimit", 10) do
              n when is_integer(n) and n >= 0 -> n
              n when is_float(n) and n >= 0 -> trunc(n)
              _ -> 10
            end

          _ -> 10
        end

      _ ->
        10
    end
  end

  defp format_stack(frames) do
    Enum.map_join(frames, "\n", fn frame ->
      suffix = "#{frame.file_name}:#{frame.line_number}:#{frame.column_number}"

      case frame.function_name do
        nil -> "    at #{suffix}"
        name -> "    at #{name} (#{suffix})"
      end
    end)
  end

  defp callsite_object(frame) do
    Heap.wrap(%{
      "getFileName" => {:builtin, "getFileName", fn _, _ -> frame.file_name end},
      "getFunction" => {:builtin, "getFunction", fn _, _ -> frame.function end},
      "getFunctionName" => {:builtin, "getFunctionName", fn _, _ -> frame.function_name || :undefined end},
      "getLineNumber" => {:builtin, "getLineNumber", fn _, _ -> frame.line_number end},
      "getColumnNumber" => {:builtin, "getColumnNumber", fn _, _ -> frame.column_number end},
      "isNative" => {:builtin, "isNative", fn _, _ -> false end}
    })
  end
end
