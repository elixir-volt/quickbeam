defmodule QuickBEAM.VM.Heap.Registry do
  @moduledoc false

  def register_module(name, exports) do
    Process.put({:qb_module, name}, exports)
    existing = Process.get(:qb_module_list, [])
    unless name in existing, do: Process.put(:qb_module_list, [name | existing])
  end

  def get_module(name), do: Process.get({:qb_module, name})

  def all_module_exports do
    Process.get(:qb_module_list, [])
    |> Enum.map(&Process.get({:qb_module, &1}))
    |> Enum.reject(&is_nil/1)
  end

  def get_symbol(key), do: Process.get({:qb_symbol_registry, key})
  def put_symbol(key, sym), do: Process.put({:qb_symbol_registry, key}, sym)
end
