defmodule QuickBEAM.VM.Builtin.WeakMap do
  @moduledoc "Defines evaluation-local WeakMap semantics for object keys."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Builtin.Map, as: MapBuiltin
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Reference

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
  def construct(%Call{} = call) do
    case MapBuiltin.construct(call) do
      {:ok, receiver, execution} = result -> validate_keys(result, receiver, execution)
      action -> action
    end
  end

  @doc "Removes a WeakMap entry."
  def delete(%Call{} = call), do: MapBuiltin.delete(call)

  @doc "Returns a WeakMap value."
  def get(%Call{} = call), do: MapBuiltin.get(call)

  @doc "Tests whether a WeakMap contains a key."
  def has(%Call{} = call), do: MapBuiltin.has(call)

  @doc "Adds or replaces a WeakMap entry."
  def set(%Call{arguments: [%Reference{} | _]} = call), do: MapBuiltin.set(call)

  def set(%Call{execution: execution}),
    do: {:error, {:type_error, :invalid_weak_map_key}, execution}

  defp validate_keys(result, receiver, execution) do
    case Heap.fetch_object(execution, receiver) do
      {:ok, %Object{internal: %{entries: entries}}} ->
        if valid_keys?(entries),
          do: result,
          else: {:error, {:type_error, :invalid_weak_map_key}, execution}

      _invalid_receiver ->
        {:error, {:type_error, :invalid_weak_map_receiver}, execution}
    end
  end

  defp valid_keys?(entries),
    do: Enum.all?(entries, fn {key, _value} -> is_struct(key, Reference) end)
end
