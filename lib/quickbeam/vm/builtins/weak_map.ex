defmodule QuickBEAM.VM.Builtins.WeakMap do
  @moduledoc "Defines evaluation-local WeakMap semantics for object keys."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtins.Map, as: MapBuiltin
  alias QuickBEAM.VM.Reference

  builtin "WeakMap",
    kind: :constructor,
    constructor: :construct,
    length: 0,
    depends_on: ["Object", "Function"] do
    prototype do
      method :delete, length: 1
      method :get, length: 1
      method :has, length: 1
      method :set, length: 2
    end
  end

  @doc "Constructs an evaluation-local weak-key map."
  def construct(%Call{} = call), do: MapBuiltin.construct(call)

  @doc "Removes a WeakMap entry."
  def delete(%Call{} = call), do: MapBuiltin.delete(call)

  @doc "Returns a WeakMap value."
  def get(%Call{} = call), do: MapBuiltin.get(call)

  @doc "Tests whether a WeakMap contains a key."
  def has(%Call{} = call), do: MapBuiltin.has(call)

  @doc "Adds or replaces a WeakMap entry."
  def set(%Call{arguments: [%Reference{} | _]} = call), do: MapBuiltin.set(call)

  def set(%Call{execution: execution}), do: {:error, :invalid_weak_map_key, execution}
end
