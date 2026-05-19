defmodule QuickBEAM.VM.Execution.RegexpState do
  @moduledoc "Process-local mutable own-property state for RegExp values backed by bytecode tuples."

  def get(ref), do: Process.get(key(ref), %{})

  def fetch(ref, property), do: Map.fetch(get(ref), property)

  def put(ref, property, value) do
    Process.put(key(ref), Map.put(get(ref), property, value))
    :ok
  end

  def fetch_internal(ref, property), do: Map.fetch(get(ref), {:internal, property})

  def put_internal(ref, property, value) do
    Process.put(key(ref), Map.put(get(ref), {:internal, property}, value))
    :ok
  end

  def delete(ref, property) do
    Process.put(key(ref), Map.delete(get(ref), property))
    :ok
  end

  def has_property?(ref, property), do: Map.has_key?(get(ref), property)

  @doc "Returns the process dictionary key for a RegExp property side table."
  def key(ref), do: {:qb_regexp_props, ref}

  @doc "Returns true when a process dictionary key belongs to RegExp property state."
  def key?({:qb_regexp_props, _ref}), do: true
  def key?(_key), do: false
end
