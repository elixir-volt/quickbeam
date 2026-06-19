defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Iterators do
  @moduledoc "Iterator and argument-rest helpers used by BEAM-compiled JavaScript."

  alias QuickBEAM.VM.{Heap, Runtime, RuntimeState}
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Properties
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.ObjectModel.Get
  alias QuickBEAM.VM.Semantics.Iterators, as: IteratorSemantics

  @doc "Creates iterator state for a JavaScript `for...of` loop."
  defdelegate for_of_start(ctx, obj), to: IteratorSemantics
  defdelegate for_of_start(obj), to: IteratorSemantics

  @doc "Advances JavaScript `for...of` iterator state."
  defdelegate for_of_next(ctx, next_fn, iter_obj), to: IteratorSemantics
  defdelegate for_of_next(next_fn, iter_obj), to: IteratorSemantics

  def next_result(ctx \\ nil, next_fn, iter_obj, val) do
    {result, next_iter} = IteratorSemantics.iterator_next_result(ctx, next_fn, iter_obj, val)
    RuntimeState.put_iterator_result_owner(result, iter_obj)
    {result, next_iter}
  end

  def check_object(_ctx, value) do
    unless IteratorSemantics.iterator_result_object?(value) do
      throw({:js_throw, Heap.make_error("iterator result is not an object", "TypeError")})
    end

    value
  end

  def call(ctx, flags, val, catch_offset, next_fn, iter_obj),
    do: IteratorSemantics.iterator_call(ctx, flags, val, catch_offset, next_fn, iter_obj)

  @doc "Creates key iteration state for a JavaScript `for...in` loop."
  defdelegate for_in_start(ctx \\ nil, obj), to: IteratorSemantics
  defdelegate for_in_next(ctx \\ nil, iter), to: IteratorSemantics

  @doc "Closes an iterator by calling its `return` method when present."
  def value_done(result) do
    try do
      done = Get.get(result, "done")

      value_done =
        if Runtime.truthy?(done) do
          {true, :undefined}
        else
          {false, Get.get(result, "value")}
        end

      RuntimeState.consume_iterator_result_owner(result)
      value_done
    catch
      {:js_throw, error} ->
        close_iterator_result_owner(result)
        throw({:js_throw, error})
    end
  end

  def close(ctx, iter_obj), do: IteratorSemantics.iterator_close(ctx, iter_obj)
  def close(iter_obj), do: IteratorSemantics.iterator_close(iter_obj)

  def close_refresh(ctx, iter_obj) do
    IteratorSemantics.iterator_close(ctx, iter_obj)
    persistent = Heap.get_persistent_globals() || %{}
    %{ctx | globals: Map.merge(ctx.globals, persistent)} |> Context.mark_dirty()
  end

  def close_for_throw(ctx, iter_obj) do
    try do
      IteratorSemantics.iterator_close(ctx, iter_obj)
    catch
      {:js_throw, _error} -> :ok
    end
  end

  @doc "Collects remaining values from an iterator into a list."
  defdelegate collect(ctx, iter, next_fn), to: IteratorSemantics, as: :collect_iterator
  defdelegate collect(iter, next_fn), to: IteratorSemantics, as: :collect_iterator

  def assignment_with_iterator_close(ctx, fun, iterators, obj, key, val) do
    try do
      case fun do
        :put_field -> Properties.put_field(ctx, obj, key, val)
        :put_array_el -> Properties.put_array_el(ctx, obj, key, val)
      end
    catch
      {:js_throw, error} ->
        Enum.each(iterators, &close_for_throw(ctx, &1))
        throw({:js_throw, error})
    end
  end

  def rest(ctx, start_idx) do
    arg_buf = RuntimeContext.arg_buf(ctx)

    rest_args =
      if start_idx < tuple_size(arg_buf) do
        Tuple.to_list(arg_buf) |> Enum.drop(start_idx)
      else
        []
      end

    Heap.wrap(rest_args)
  end

  defp close_iterator_result_owner(result) do
    case RuntimeState.consume_iterator_result_owner(result) do
      nil ->
        :ok

      iter_obj ->
        try do
          IteratorSemantics.iterator_close(iter_obj)
        catch
          {:js_throw, _error} -> :ok
        end
    end
  end
end
