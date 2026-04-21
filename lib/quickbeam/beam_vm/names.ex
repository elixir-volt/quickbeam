defmodule QuickBEAM.BeamVM.Names do
  @moduledoc false

  alias QuickBEAM.BeamVM.{Bytecode, Heap, PredefinedAtoms}
  alias QuickBEAM.BeamVM.Interpreter.Context
  alias QuickBEAM.BeamVM.Interpreter.Values

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
    PredefinedAtoms.lookup(idx) || "atom_#{idx}"
  end

  def resolve_atom(_atoms, {:tagged_int, val}), do: val

  def resolve_atom(atoms, idx) when is_integer(idx) and idx >= 0 and is_tuple(atoms) do
    if idx < tuple_size(atoms), do: elem(atoms, idx), else: {:atom, idx}
  end

  def resolve_atom(_atoms, other) when is_binary(other), do: other
  def resolve_atom(_atoms, other) when is_integer(other), do: Integer.to_string(other)
  def resolve_atom(_atoms, {:atom, n}), do: "atom_#{n}"
  def resolve_atom(_atoms, other), do: inspect(other)

  def resolve_display_name(name, atoms \\ Heap.get_atoms())

  def resolve_display_name(name, _atoms) when is_binary(name), do: name
  def resolve_display_name({:predefined, idx}, _atoms), do: PredefinedAtoms.lookup(idx)
  def resolve_display_name(idx, atoms) when is_integer(idx), do: resolve_atom(atoms, idx)
  def resolve_display_name(_name, _atoms), do: nil

  def function_name(name_val) do
    case name_val do
      s when is_binary(s) -> s
      n when is_number(n) -> Values.stringify(n)
      {:symbol, desc, _} -> "[" <> desc <> "]"
      {:symbol, desc} -> "[" <> desc <> "]"
      _ -> ""
    end
  end

  def rename_function({:closure, captured, %Bytecode.Function{} = fun}, name),
    do: {:closure, captured, %{fun | name: name}}

  def rename_function(%Bytecode.Function{} = fun, name), do: %{fun | name: name}
  def rename_function({:builtin, _, cb}, name), do: {:builtin, name, cb}
  def rename_function(other, _name), do: other

  def normalize_property_key(idx) do
    case idx do
      i when is_integer(i) -> Integer.to_string(i)
      {:symbol, _} = sym -> sym
      {:symbol, _, _} = sym -> sym
      s when is_binary(s) -> s
      other -> Kernel.to_string(other)
    end
  end
end
