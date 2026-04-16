defmodule QuickBEAM.BeamVM.Interpreter.Scope do
  alias QuickBEAM.BeamVM.PredefinedAtoms
  alias QuickBEAM.BeamVM.Interpreter.Ctx

  @js_atom_end 229

  def resolve_const(cpool, idx) when is_list(cpool) and idx < length(cpool), do: Enum.at(cpool, idx)
  def resolve_const(_cpool, idx), do: {:const_ref, idx}

  def resolve_atom(%Ctx{atoms: atoms}, idx), do: resolve_atom(atoms, idx)

  def resolve_atom(_atoms, :empty_string), do: ""
  def resolve_atom(_atoms, {:predefined, idx}) when idx < @js_atom_end do
    PredefinedAtoms.lookup(idx) || {:predefined_atom, idx}
  end
  def resolve_atom(_atoms, {:tagged_int, val}), do: val
  def resolve_atom(atoms, idx) when is_integer(idx) and idx >= 0 and is_tuple(atoms) do
    if idx < tuple_size(atoms), do: elem(atoms, idx), else: {:atom, idx}
  end
  def resolve_atom(_atoms, other), do: other

  def resolve_global(%Ctx{globals: globals} = ctx, atom_idx) do
    name = resolve_atom(ctx, atom_idx)
    case Map.fetch(globals, name) do
      {:ok, val} -> {:found, val}
      :error -> :not_found
    end
  end

  def set_global(%Ctx{globals: globals} = ctx, atom_idx, val) do
    name = resolve_atom(ctx, atom_idx)
    %{ctx | globals: Map.put(globals, name, val)}
  end

  def get_arg_value(%Ctx{arg_buf: arg_buf}, idx) do
    if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
  end
end
