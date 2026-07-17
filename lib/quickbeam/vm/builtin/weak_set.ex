defmodule QuickBEAM.VM.Builtin.WeakSet do
  @moduledoc "Defines evaluation-local WeakSet semantics for object values."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtin.Set, as: SetBuiltin
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Reference

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
  def construct(%Call{} = call) do
    case SetBuiltin.construct(call) do
      {:ok, receiver, execution} = result -> validate_values(result, receiver, execution)
      action -> action
    end
  end

  @doc "Adds a WeakSet value."
  def add(%Call{arguments: [%Reference{} | _]} = call), do: SetBuiltin.add(call)

  def add(%Call{execution: execution}),
    do: {:error, {:type_error, :invalid_weak_set_value}, execution}

  @doc "Removes a WeakSet value."
  def delete(%Call{} = call), do: SetBuiltin.delete(call)

  @doc "Tests whether a WeakSet contains a value."
  def has(%Call{} = call), do: SetBuiltin.has(call)

  defp validate_values(result, receiver, execution) do
    case Heap.fetch_object(execution, receiver) do
      {:ok, %Object{internal: %{values: values}}} ->
        if Enum.all?(values, &is_struct(&1, Reference)),
          do: result,
          else: {:error, {:type_error, :invalid_weak_set_value}, execution}

      _invalid_receiver ->
        {:error, {:type_error, :invalid_weak_set_receiver}, execution}
    end
  end
end
