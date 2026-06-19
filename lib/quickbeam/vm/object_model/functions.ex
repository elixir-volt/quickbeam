defmodule QuickBEAM.VM.ObjectModel.Functions do
  @moduledoc "Function object helpers for names, home objects, and super method dispatch metadata."

  alias QuickBEAM.VM.{Heap, Names}
  alias QuickBEAM.VM.Heap.Caches

  @doc "Converts a JavaScript property name value into a function display name."
  def function_name(name_val), do: Names.function_name(name_val)
  @doc "Returns a function value with its JavaScript name metadata updated."
  def rename(fun, name), do: Names.rename_function(fun, name)

  @doc "Sets a function name from an atom-table index."
  def set_name_atom(fun, atom_idx, atoms \\ Heap.get_atoms()) do
    rename(fun, Names.resolve_atom(atoms, atom_idx))
  end

  @doc "Sets a function name from a computed JavaScript property value."
  def set_name_computed(fun, name_val), do: rename(fun, function_name(name_val))

  @doc "Records the home object needed by methods that use `super`."
  def put_home_object(method, target) do
    if needs_home_object?(method) do
      key = home_object_key(method)
      if key != nil, do: Caches.put_home_object(key, target)
    end

    method
  end

  @doc "Looks up the home object associated with the current function."
  def current_home_object(current_func) do
    Caches.get_home_object(home_object_key(current_func))
  end

  @doc "Returns the stable cache key used for a function's home object."
  def home_object_key({:closure, _, %QuickBEAM.VM.Function{} = fun}), do: home_object_key(fun)

  def home_object_key(%QuickBEAM.VM.Function{id: id}) when is_integer(id), do: {:function, id}

  def home_object_key(%QuickBEAM.VM.Function{} = fun), do: {:function, :erlang.phash2(fun)}
  def home_object_key(_), do: nil

  @doc "Returns whether a function value needs home-object metadata for super lookup."
  def needs_home_object?({:closure, _, %QuickBEAM.VM.Function{need_home_object: true}}), do: true
  def needs_home_object?(%QuickBEAM.VM.Function{need_home_object: true}), do: true
  def needs_home_object?(_), do: false
end
