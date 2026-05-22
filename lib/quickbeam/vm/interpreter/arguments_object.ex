defmodule QuickBEAM.VM.Interpreter.ArgumentsObject do
  @moduledoc "Arguments object creation and process-local caching for interpreter frames."

  alias QuickBEAM.VM.{Heap, RuntimeState, Value}
  alias QuickBEAM.VM.Interpreter.{Context, Frame}

  require Frame

  def get(%Context{} = ctx, frame, opts \\ []) do
    key = RuntimeState.arguments_object_key(ctx.current_func, ctx.arg_buf)

    case Map.fetch(ctx.globals, key) do
      {:ok, arguments} -> arguments
      :error -> cached(ctx, frame, key, opts)
    end
  end

  def store_global(%Context{} = ctx, arguments) do
    key = RuntimeState.arguments_object_key(ctx.current_func, ctx.arg_buf)

    %{
      ctx
      | globals:
          ctx.globals
          |> Map.put("arguments", arguments)
          |> Map.put(key, arguments)
    }
  end

  defp cached(ctx, frame, key, opts) do
    case RuntimeState.get_arguments_object(key) do
      nil ->
        arguments =
          Heap.wrap_arguments(Tuple.to_list(ctx.arg_buf),
            strict: Value.strict_context?(ctx),
            callee: ctx.current_func,
            mapped: mapped_argument_cells(ctx, frame, opts)
          )

        RuntimeState.put_arguments_object(key, arguments)

      arguments ->
        arguments
    end
  end

  defp mapped_argument_cells(ctx, frame, opts) do
    if mapped_arguments?(ctx) do
      locals = function_locals(ctx)
      var_refs = elem(frame, Frame.var_refs())
      offset = var_ref_offset(ctx, opts)
      count = min(tuple_size(ctx.arg_buf), length(locals))

      if count == 0 do
        %{}
      else
        last_parameter_index = last_parameter_index_by_var_ref(locals, count)

        0..(count - 1)//1
        |> Enum.reduce(%{}, fn index, acc ->
          mapped_argument_cell(locals, var_refs, offset, last_parameter_index, index, acc)
        end)
      end
    else
      %{}
    end
  end

  defp mapped_argument_cell(locals, var_refs, offset, last_parameter_index, index, acc) do
    case Enum.at(locals, index) do
      %{var_ref_idx: ref_idx}
      when is_integer(ref_idx) and offset + ref_idx < tuple_size(var_refs) ->
        if Map.get(last_parameter_index, ref_idx) == index do
          case elem(var_refs, offset + ref_idx) do
            {:cell, _} = cell -> Map.put(acc, index, cell)
            _ -> acc
          end
        else
          acc
        end

      _ ->
        acc
    end
  end

  defp last_parameter_index_by_var_ref(locals, count) do
    0..(count - 1)//1
    |> Enum.reduce(%{}, fn index, acc ->
      case Enum.at(locals, index) do
        %{var_ref_idx: ref_idx} when is_integer(ref_idx) -> Map.put(acc, ref_idx, index)
        _ -> acc
      end
    end)
  end

  defp mapped_arguments?(ctx) do
    case ctx.current_func do
      {:closure, _, %QuickBEAM.VM.Function{} = fun} ->
        not fun.is_strict_mode and fun.has_simple_parameter_list

      %QuickBEAM.VM.Function{} = fun ->
        not fun.is_strict_mode and fun.has_simple_parameter_list

      _ ->
        false
    end
  end

  defp function_locals(ctx) do
    case ctx.current_func do
      {:closure, _, %QuickBEAM.VM.Function{locals: locals}} -> locals
      %QuickBEAM.VM.Function{locals: locals} -> locals
      _ -> []
    end
  end

  defp var_ref_offset(ctx, opts) do
    case Keyword.get(opts, :var_ref_offset, :closure) do
      :closure -> closure_ref_count(ctx)
      :raw -> 0
    end
  end

  defp closure_ref_count(ctx) do
    case ctx.current_func do
      {:closure, captured, _} when is_map(captured) -> map_size(captured)
      _ -> 0
    end
  end
end
