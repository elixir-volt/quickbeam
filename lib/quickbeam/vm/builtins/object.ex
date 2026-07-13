defmodule QuickBEAM.VM.Builtins.Object do
  @moduledoc "Defines declarative low-risk and resumable `Object` static methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Heap, Properties, Reference, Value}

  builtin "Object", kind: :extension do
    static("assign", :assign, length: 2)
    static("create", :create, length: 2)
    static("getOwnPropertyNames", :get_own_property_names, length: 1)
    static("getPrototypeOf", :get_prototype_of, length: 1)
    static("keys", :keys, length: 1)
    static("setPrototypeOf", :set_prototype_of, length: 2)
  end

  @doc "Plans resumable `Object.assign` property reads and writes."
  def assign(%Call{
        arguments: [%Reference{} = target | sources],
        caller: caller,
        tail?: tail?,
        execution: execution
      }),
      do: {:action, {:object_assign, target, sources, caller, execution, tail?}}

  def assign(%Call{execution: execution}), do: {:error, :not_an_object, execution}

  @doc "Implements `Object.create` for null or owner-local prototypes."
  def create(%Call{arguments: [prototype | _], execution: execution})
      when is_nil(prototype) or is_struct(prototype, Reference) do
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    {:ok, object, execution}
  end

  def create(%Call{execution: execution}), do: {:error, :invalid_prototype, execution}

  @doc "Implements `Object.getOwnPropertyNames`."
  def get_own_property_names(%Call{
        arguments: [%Reference{} = target | _],
        execution: execution
      }) do
    case Properties.own_property_names(target, execution) do
      {:ok, keys} ->
        {array, execution} = array_from(keys, execution)
        {:ok, array, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def get_own_property_names(%Call{execution: execution}),
    do: {:error, :not_an_object, execution}

  @doc "Implements `Object.getPrototypeOf`."
  def get_prototype_of(%Call{arguments: [%Reference{} = target | _], execution: execution}) do
    case Properties.prototype(target, execution) do
      {:ok, prototype} -> {:ok, prototype, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def get_prototype_of(%Call{execution: execution}), do: {:error, :not_an_object, execution}

  @doc "Implements `Object.keys` with canonical enumerable-key ordering."
  def keys(%Call{arguments: [value | _], execution: execution}) do
    with {:ok, keys} <- own_keys(value, execution) do
      keys = Enum.map(keys, &Value.to_string_value/1)
      {array, execution} = array_from(keys, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def keys(%Call{execution: execution}), do: {:error, :missing_argument, execution}

  @doc "Implements `Object.setPrototypeOf` with owner-local cycle validation."
  def set_prototype_of(%Call{
        arguments: [%Reference{} = target, prototype | _],
        execution: execution
      })
      when is_nil(prototype) or is_struct(prototype, Reference) do
    case Properties.set_prototype(target, prototype, execution) do
      {:ok, execution} -> {:ok, target, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def set_prototype_of(%Call{execution: execution}),
    do: {:error, :invalid_prototype, execution}

  defp own_keys(%Reference{} = reference, execution),
    do: Properties.enumerable_keys(reference, execution)

  defp own_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  defp own_keys([], _execution), do: {:ok, []}

  defp own_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  defp own_keys(_value, _execution), do: {:ok, []}

  defp array_from(values, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Properties.define(array, index, value, execution)
        execution
      end)

    {array, execution}
  end
end
