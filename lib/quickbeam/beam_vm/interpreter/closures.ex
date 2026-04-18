defmodule QuickBEAM.BeamVM.Interpreter.Closures do
  @compile {:inline, read_cell: 1, write_cell: 2, read_captured_local: 4, write_captured_local: 5}
  @moduledoc false

  alias QuickBEAM.BeamVM.Heap

  def read_cell({:cell, ref}), do: Heap.get_cell(ref)
  def read_cell(_), do: :undefined

  def write_cell({:cell, ref}, val), do: Heap.put_cell(ref, val)
  def write_cell(_, _), do: :ok

  def read_captured_local(l2v, idx, locals, var_refs) do
    case Map.get(l2v, idx) do
      nil ->
        elem(locals, idx)

      vref_idx ->
        case elem(var_refs, vref_idx) do
          {:cell, ref} -> Heap.get_cell(ref)
          val -> val
        end
    end
  end

  def write_captured_local(l2v, idx, val, _locals, var_refs) do
    case Map.get(l2v, idx) do
      nil ->
        :ok

      vref_idx ->
        case elem(var_refs, vref_idx) do
          {:cell, ref} -> Heap.put_cell(ref, val)
          _ -> :ok
        end
    end
  end

  def setup_captured_locals(%{locals: []}, locals, var_refs, _args) do
    vrefs = if is_tuple(var_refs), do: var_refs, else: List.to_tuple(var_refs)
    {locals, vrefs, %{}}
  end

  def setup_captured_locals(fun, locals, var_refs, args) do
    arg_buf = List.to_tuple(args)
    vrefs = if is_tuple(var_refs), do: Tuple.to_list(var_refs), else: var_refs

    {locals, vrefs, l2v} =
      for {vd, local_idx} <- Enum.with_index(fun.locals),
          vd.is_captured,
          reduce: {locals, vrefs, %{}} do
        {acc_locals, acc_vrefs, acc_l2v} ->
          val =
            if local_idx < tuple_size(arg_buf),
              do: elem(arg_buf, local_idx),
              else: elem(acc_locals, local_idx)

          acc_locals = put_elem(acc_locals, local_idx, val)
          ref = make_ref()
          Heap.put_cell(ref, val)
          acc_vrefs = ensure_vref_size(acc_vrefs, vd.var_ref_idx, {:cell, ref})
          acc_l2v = Map.put(acc_l2v, local_idx, vd.var_ref_idx)
          {acc_locals, acc_vrefs, acc_l2v}
      end

    {locals, List.to_tuple(vrefs), l2v}
  end

  def ensure_vref_size(vrefs, idx, val) do
    vrefs =
      if idx >= length(vrefs),
        do: vrefs ++ List.duplicate(:undefined, idx + 1 - length(vrefs)),
        else: vrefs

    List.replace_at(vrefs, idx, val)
  end
end
