defmodule QuickBEAM.VM.Interpreter.Closures do
  @moduledoc "Closure variable access: read and write shared capture cells and captured locals."
  @compile {:inline, read_cell: 1, write_cell: 2, read_captured_local: 4, write_captured_local: 5}

  alias QuickBEAM.VM.Heap

  @doc "Reads a captured closure cell."
  def read_cell({:cell, ref}), do: Heap.get_cell(ref)
  def read_cell(_), do: :undefined

  @doc "Writes a captured closure cell."
  def write_cell({:cell, ref}, val), do: Heap.put_cell(ref, val)
  def write_cell(_, _), do: :ok

  @doc "Reads a captured local variable value."
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

  @doc "Writes a captured local variable value."
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

  @doc "Initializes captured locals for closure execution."
  def setup_captured_locals(%{locals: []}, locals, var_refs, _args) do
    vrefs = if is_tuple(var_refs), do: var_refs, else: List.to_tuple(var_refs)
    {locals, vrefs, %{}}
  end

  def setup_captured_locals(fun, locals, var_refs, args) do
    arg_buf = List.to_tuple(args)
    vrefs = if is_tuple(var_refs), do: var_refs, else: List.to_tuple(var_refs)

    setup_captured_locals(fun.locals, 0, locals, vrefs, tuple_size(vrefs), arg_buf, %{})
  end

  defp setup_captured_locals([], _idx, locals, vrefs, _closure_ref_count, _arg_buf, l2v),
    do: {locals, vrefs, l2v}

  defp setup_captured_locals(
         [%{is_captured: true, var_ref_idx: var_ref_idx} | rest],
         idx,
         locals,
         vrefs,
         closure_ref_count,
         arg_buf,
         l2v
       ) do
    val =
      if idx < tuple_size(arg_buf),
        do: elem(arg_buf, idx),
        else: elem(locals, idx)

    ref = make_ref()
    Heap.put_cell(ref, val)
    local_ref_idx = closure_ref_count + var_ref_idx

    setup_captured_locals(
      rest,
      idx + 1,
      put_elem(locals, idx, val),
      put_vref(vrefs, local_ref_idx, {:cell, ref}),
      closure_ref_count,
      arg_buf,
      Map.put(l2v, idx, local_ref_idx)
    )
  end

  defp setup_captured_locals([_ | rest], idx, locals, vrefs, closure_ref_count, arg_buf, l2v),
    do: setup_captured_locals(rest, idx + 1, locals, vrefs, closure_ref_count, arg_buf, l2v)

  defp put_vref(vrefs, idx, val) when idx < tuple_size(vrefs), do: put_elem(vrefs, idx, val)

  defp put_vref(vrefs, idx, val) do
    vrefs
    |> Tuple.to_list()
    |> Kernel.++(List.duplicate(:undefined, idx + 1 - tuple_size(vrefs)))
    |> List.replace_at(idx, val)
    |> List.to_tuple()
  end
end
