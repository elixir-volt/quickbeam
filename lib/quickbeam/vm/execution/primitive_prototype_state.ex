defmodule QuickBEAM.VM.Execution.PrimitivePrototypeState do
  @moduledoc "Process-local state for primitive prototype overrides observed by abstract operations."

  @primitive_types ["Boolean", "Number", "String", "Symbol"]

  def put_then(type, value) when type in @primitive_types do
    Process.put(then_key(type), value)
    :ok
  end

  def then_override(type) when type in @primitive_types, do: Process.get(then_key(type))
  def then_override(_type), do: nil

  defp then_key(type), do: {:qb_primitive_prototype_then, type}
end
