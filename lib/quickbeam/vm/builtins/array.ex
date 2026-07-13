defmodule QuickBEAM.VM.Builtins.Array do
  @moduledoc "Defines declarative additions to the core `Array` constructor."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Heap, Object, Properties, Property, Reference, Value}

  builtin "Array", kind: :extension do
    static("isArray", :is_array, length: 1)

    prototype do
      method("concat", :concat, length: 1)
      method("filter", :filter, length: 1)
      method("forEach", :for_each, length: 1)
      method("join", :join, length: 1)
      method("map", :map, length: 1)
      method("push", :push, length: 1)
      method("reduce", :reduce, length: 1)
      method("slice", :slice, length: 2)
      method("some", :some, length: 1)
    end
  end

  @doc "Implements `Array.isArray`."
  def is_array(%Call{arguments: arguments, execution: execution}) do
    value = List.first(arguments, :undefined)

    result =
      case value do
        %Reference{} = reference -> Properties.kind(reference, execution) == :array
        value -> is_list(value)
      end

    {:ok, result, execution}
  end

  @doc "Implements sparse `Array.prototype.concat`."
  def concat(%Call{this: receiver, arguments: arguments, execution: execution}) do
    with {:ok, entries} <- array_entries(receiver, execution) do
      entries = Enum.reduce(arguments, entries, &(&2 ++ concat_entries(&1, execution)))
      {array, execution} = array_from_entries(entries, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  @doc "Implements `Array.prototype.join`, treating holes and nullish values as empty strings."
  def join(%Call{this: receiver, arguments: arguments, execution: execution}) do
    separator =
      case arguments do
        [] -> ","
        [:undefined | _] -> ","
        [value | _] -> Value.to_string_value(value)
      end

    with {:ok, entries} <- array_entries(receiver, execution) do
      value =
        Enum.map_join(entries, separator, fn
          :hole -> ""
          {:present, value} when value in [nil, :undefined] -> ""
          {:present, value} -> Value.to_string_value(value)
        end)

      {:ok, value, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  @doc "Implements `Array.prototype.push`."
  def push(%Call{this: %Reference{} = array, arguments: values, execution: execution}) do
    case Heap.fetch_object(execution, array) do
      {:ok, %Object{kind: :array, length: length}} ->
        execution =
          values
          |> Enum.with_index(length)
          |> Enum.reduce(execution, fn {value, index}, execution ->
            {:ok, execution} = Properties.put(array, index, value, execution)
            execution
          end)

        {:ok, length + Kernel.length(values), execution}

      _not_array ->
        {:error, :not_an_array, execution}
    end
  end

  def push(%Call{execution: execution}), do: {:error, :not_an_array, execution}

  @doc "Implements sparse `Array.prototype.slice`."
  def slice(%Call{this: receiver, arguments: arguments, execution: execution}) do
    with {:ok, entries} <- array_entries(receiver, execution) do
      {start, length} = slice_range(length(entries), arguments)
      {array, execution} = array_from_entries(Enum.slice(entries, start, length), execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  @doc "Plans resumable `Array.prototype.filter` iteration."
  def filter(%Call{} = call), do: iteration_action("filter", call)

  @doc "Plans resumable `Array.prototype.forEach` iteration."
  def for_each(%Call{} = call), do: iteration_action("forEach", call)

  @doc "Plans resumable `Array.prototype.map` iteration."
  def map(%Call{} = call), do: iteration_action("map", call)

  @doc "Plans resumable `Array.prototype.reduce` iteration."
  def reduce(%Call{} = call), do: iteration_action("reduce", call)

  @doc "Plans resumable `Array.prototype.some` iteration."
  def some(%Call{} = call), do: iteration_action("some", call)

  defp array_entries(value, _execution) when is_list(value),
    do: {:ok, Enum.map(value, &{:present, &1})}

  defp array_entries(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length, properties: properties}} ->
        entries =
          if length == 0 do
            []
          else
            for index <- 0..(length - 1) do
              case Map.get(properties, index) do
                %Property{value: value} -> {:present, value}
                nil -> :hole
              end
            end
          end

        {:ok, entries}

      _not_array ->
        {:error, :not_an_array}
    end
  end

  defp array_entries(_value, _execution), do: {:error, :not_an_array}

  defp concat_entries(value, execution) do
    case array_entries(value, execution) do
      {:ok, entries} -> entries
      {:error, _reason} -> [{:present, value}]
    end
  end

  defp array_from_entries(entries, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      entries
      |> Enum.with_index()
      |> Enum.reduce(execution, fn
        {{:present, value}, index}, execution ->
          {:ok, execution} = Properties.define(array, index, value, execution)
          execution

        {:hole, _index}, execution ->
          execution
      end)

    {:ok, execution} = Properties.define(array, "length", length(entries), execution)
    {array, execution}
  end

  defp slice_range(size, arguments) do
    start =
      case arguments do
        [start | _] -> normalize_slice_index(start, size)
        [] -> 0
      end

    finish =
      case arguments do
        [_start, finish | _] -> normalize_slice_index(finish, size)
        _ -> size
      end

    {start, max(finish - start, 0)}
  end

  defp normalize_slice_index(value, size) do
    case Value.to_number(value) do
      :infinity -> size
      :neg_infinity -> 0
      :nan -> 0
      index when is_number(index) -> normalize_index(trunc(index), size)
      _value -> 0
    end
  end

  defp normalize_index(index, size) when index < 0, do: max(size + index, 0)
  defp normalize_index(index, size), do: min(index, size)

  defp iteration_action(method, %Call{
         arguments: arguments,
         this: receiver,
         caller: caller,
         tail?: tail?,
         execution: execution
       }) do
    {:action, {:array_iteration, method, receiver, arguments, caller, execution, tail?}}
  end
end
