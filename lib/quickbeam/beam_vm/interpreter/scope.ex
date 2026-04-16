defmodule QuickBEAM.BeamVM.Interpreter.Scope do
  alias QuickBEAM.BeamVM.PredefinedAtoms

  @js_atom_end 229

  def resolve_const(cpool, idx) when is_list(cpool) and idx < length(cpool), do: Enum.at(cpool, idx)
  def resolve_const(_cpool, idx), do: {:const_ref, idx}

  def resolve_atom(:empty_string), do: ""
  def resolve_atom({:predefined, idx}) when idx < @js_atom_end do
    PredefinedAtoms.lookup(idx) || {:predefined_atom, idx}
  end
  def resolve_atom({:tagged_int, val}), do: val
  def resolve_atom(idx) when is_integer(idx) and idx >= 0 do
    atoms = Process.get(:qb_atoms, {})
    if idx < tuple_size(atoms), do: elem(atoms, idx), else: {:atom, idx}
  end
  def resolve_atom(other), do: other

  def resolve_global(atom_idx) do
    name = resolve_atom(atom_idx)
    globals = Process.get(:qb_globals, %{})
    case Map.fetch(globals, name) do
      {:ok, val} -> {:found, val}
      :error -> :not_found
    end
  end

  def set_global(atom_idx, val) do
    name = resolve_atom(atom_idx)
    globals = Process.get(:qb_globals, %{})
    Process.put(:qb_globals, Map.put(globals, name, val))
  end

  def get_arg_value(idx) do
    arg_buf = Process.get(:qb_arg_buf, {})
    if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
  end
end
