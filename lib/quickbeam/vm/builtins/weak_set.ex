defmodule QuickBEAM.VM.Builtins.WeakSet do
  @moduledoc "Defines evaluation-local WeakSet semantics for object values."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtins.Set, as: SetBuiltin
  alias QuickBEAM.VM.Reference

  builtin "WeakSet",
    kind: :constructor,
    constructor: :construct,
    length: 0,
    depends_on: ["Object", "Function", "Symbol"] do
    prototype do
      method :add, length: 1
      method :delete, length: 1
      method :has, length: 1
    end
  end

  @doc "Constructs an evaluation-local weak-value set."
  def construct(%Call{} = call), do: SetBuiltin.construct(call)

  @doc "Adds a WeakSet value."
  def add(%Call{arguments: [%Reference{} | _]} = call), do: SetBuiltin.add(call)

  def add(%Call{execution: execution}), do: {:error, :invalid_weak_set_value, execution}

  @doc "Removes a WeakSet value."
  def delete(%Call{} = call), do: SetBuiltin.delete(call)

  @doc "Tests whether a WeakSet contains a value."
  def has(%Call{} = call), do: SetBuiltin.has(call)
end
