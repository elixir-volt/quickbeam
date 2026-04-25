defmodule QuickBEAM.VM.ObjectModel.Functions do
  @moduledoc false

  alias QuickBEAM.VM.{Bytecode, Heap, Names}
  alias QuickBEAM.VM.Heap.Caches

  def function_name(name_val), do: Names.function_name(name_val)
  def rename(fun, name), do: Names.rename_function(fun, name)

  def set_name_atom(fun, atom_idx, atoms \\ Heap.get_atoms()) do
    rename(fun, Names.resolve_atom(atoms, atom_idx))
  end

  def set_name_computed(fun, name_val), do: rename(fun, function_name(name_val))

  def put_home_object(method, target) do
    if needs_home_object?(method) do
      key = home_object_key(method)
      if key != nil, do: Caches.put_home_object(key, target)
    end

    method
  end

  def current_home_object(current_func) do
    Caches.get_home_object(home_object_key(current_func))
  end

  def home_object_key({:closure, _, %Bytecode.Function{byte_code: byte_code}}), do: byte_code
  def home_object_key(%Bytecode.Function{byte_code: byte_code}), do: byte_code
  def home_object_key(_), do: nil

  defp needs_home_object?({:closure, _, %Bytecode.Function{need_home_object: true}}), do: true
  defp needs_home_object?(%Bytecode.Function{need_home_object: true}), do: true
  defp needs_home_object?(_), do: false
end
