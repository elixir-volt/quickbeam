defmodule QuickBEAM.BeamVM.Interpreter.ClosureBuilder do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap}
  alias QuickBEAM.BeamVM.Interpreter.Context

  def build(%Bytecode.Function{} = fun, locals, vrefs, l2v, %Context{} = ctx) do
    parent_arg_count = current_function_arg_count(ctx)

    captured =
      for cv <- fun.closure_vars, into: %{} do
        {capture_key(cv), capture_var(cv, locals, vrefs, l2v, parent_arg_count)}
      end

    {:closure, captured, fun}
  end

  def build(other, _locals, _vrefs, _l2v, _ctx), do: other

  def inherit_parent_vrefs({:closure, captured, %Bytecode.Function{} = fun}, parent_vrefs)
      when is_tuple(parent_vrefs) do
    extra =
      if tuple_size(parent_vrefs) == 0 do
        %{}
      else
        for i <- 0..(tuple_size(parent_vrefs) - 1),
            not Map.has_key?(captured, capture_key(2, i)),
            into: %{} do
          {capture_key(2, i), elem(parent_vrefs, i)}
        end
      end

    {:closure, Map.merge(extra, captured), fun}
  end

  def inherit_parent_vrefs(closure, _parent_vrefs), do: closure

  def ctor_var_refs(%Bytecode.Function{} = fun, captured \\ %{}) do
    cell_ref = make_ref()
    Heap.put_cell(cell_ref, false)

    case fun.closure_vars do
      [] ->
        [{:cell, cell_ref}]

      closure_vars ->
        Enum.map(closure_vars, &Map.get(captured, capture_key(&1), {:cell, cell_ref}))
    end
  end

  def capture_key(%{closure_type: type, var_idx: idx}), do: capture_key(type, idx)
  def capture_key(type, idx), do: {type, idx}

  defp capture_var(%{closure_type: 2, var_idx: idx}, _locals, vrefs, _l2v, _arg_count)
       when idx < tuple_size(vrefs) do
    case elem(vrefs, idx) do
      {:cell, _} = existing ->
        existing

      val ->
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}
    end
  end

  defp capture_var(%{closure_type: 0, var_idx: idx}, locals, vrefs, l2v, arg_count) do
    capture_local_var(idx + arg_count, locals, vrefs, l2v)
  end

  defp capture_var(%{var_idx: idx}, locals, vrefs, l2v, _arg_count) do
    capture_local_var(idx, locals, vrefs, l2v)
  end

  defp capture_local_var(idx, locals, vrefs, l2v) do
    case Map.get(l2v, idx) do
      nil ->
        val = if idx < tuple_size(locals), do: elem(locals, idx), else: :undefined
        ref = make_ref()
        Heap.put_cell(ref, val)
        {:cell, ref}

      vref_idx ->
        case elem(vrefs, vref_idx) do
          {:cell, _} = existing ->
            existing

          _ ->
            val = elem(locals, idx)
            ref = make_ref()
            Heap.put_cell(ref, val)
            {:cell, ref}
        end
    end
  end

  defp current_function_arg_count(%Context{
         current_func: {:closure, _, %Bytecode.Function{arg_count: n}}
       }),
       do: n

  defp current_function_arg_count(%Context{current_func: %Bytecode.Function{arg_count: n}}), do: n
  defp current_function_arg_count(%Context{arg_buf: arg_buf}), do: tuple_size(arg_buf)
end
