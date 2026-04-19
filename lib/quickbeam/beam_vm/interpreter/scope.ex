defmodule QuickBEAM.BeamVM.Interpreter.Scope do
  @moduledoc false
  @compile {:inline,
            resolve_const: 2, resolve_atom: 2, resolve_global: 2, set_global: 3, get_arg_value: 2}
  alias QuickBEAM.BeamVM.Heap
  alias QuickBEAM.BeamVM.Interpreter.Context
  alias QuickBEAM.BeamVM.PredefinedAtoms

  @js_atom_end QuickBEAM.BeamVM.Opcodes.js_atom_end()

  def resolve_const(cpool, idx) when is_tuple(cpool) and idx < tuple_size(cpool) do
    case elem(cpool, idx) do
      {:array, list} when is_list(list) ->
        ref = make_ref()
        Heap.put_obj(ref, list)
        {:obj, ref}

      other ->
        other
    end
  end

  def resolve_const(_cpool, idx), do: {:const_ref, idx}

  def resolve_atom(%Context{atoms: atoms}, idx), do: resolve_atom(atoms, idx)

  def resolve_atom(_atoms, :empty_string), do: ""

  def resolve_atom(_atoms, {:predefined, idx}) when idx < @js_atom_end do
    PredefinedAtoms.lookup(idx) || {:predefined_atom, idx}
  end

  def resolve_atom(_atoms, {:tagged_int, val}), do: val

  def resolve_atom(atoms, idx) when is_integer(idx) and idx >= 0 and is_tuple(atoms) do
    if idx < tuple_size(atoms), do: elem(atoms, idx), else: {:atom, idx}
  end

  def resolve_atom(_atoms, other) when is_binary(other), do: other
  def resolve_atom(_atoms, other) when is_integer(other), do: Integer.to_string(other)
  def resolve_atom(_atoms, {:atom, n}), do: "atom_#{n}"
  def resolve_atom(_atoms, other), do: inspect(other)

  def resolve_global(%Context{globals: globals} = ctx, atom_idx) do
    name = resolve_atom(ctx, atom_idx)

    case Map.fetch(globals, name) do
      {:ok, val} -> {:found, val}
      :error -> :not_found
    end
  end

  def set_global(%Context{globals: globals} = ctx, atom_idx, val) do
    name = resolve_atom(ctx, atom_idx)
    %{ctx | globals: Map.put(globals, name, val)}
  end

  def get_arg_value(%Context{arg_buf: arg_buf}, idx) do
    if idx < tuple_size(arg_buf), do: elem(arg_buf, idx), else: :undefined
  end
end
