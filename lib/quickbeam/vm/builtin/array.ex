defmodule QuickBEAM.VM.Builtin.Array do
  @moduledoc "Defines declarative additions to the core `Array` constructor."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.Value

  builtin "Array",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function"] do
    static :array?, js: "isArray", length: 1

    prototype kind: :array, extends: "Object", default_for: :array do
      method :concat, length: 1
      method :filter, length: 1
      method :for_each, js: "forEach", length: 1
      method :includes, length: 1
      method :join, length: 1
      method :map, length: 1
      method :push, length: 1
      method :reduce, length: 1
      method :slice, length: 2
      method :some, length: 1
      method :sort, length: 1
    end
  end

  @doc "Constructs an Array from a length or argument list."
  def construct(%Call{arguments: [length], execution: execution})
      when is_integer(length) and length in 0..4_294_967_295 do
    {array, execution} = Heap.allocate(execution, :array, length: length)
    {:ok, array, execution}
  end

  def construct(%Call{arguments: [length], execution: execution})
      when is_float(length) and length >= 0 and length <= 4_294_967_295 and
             trunc(length) == length do
    {array, execution} = Heap.allocate(execution, :array, length: trunc(length))
    {:ok, array, execution}
  end

  def construct(%Call{arguments: [length], execution: execution} = call)
      when is_number(length) or length in [:nan, :infinity, :neg_infinity] do
    Builtin.action({:error, {:range_error, :invalid_array_length}, call.caller, execution})
  end

  def construct(%Call{arguments: arguments, execution: execution}) do
    entries = Enum.map(arguments, &{:present, &1})
    {array, execution} = from_entries(entries, execution)
    {:ok, array, execution}
  end

  @doc "Implements `Array.isArray`."
  def array?(%Call{arguments: arguments, execution: execution}) do
    value = List.first(arguments, :undefined)

    result =
      case value do
        %Reference{} = reference -> Property.kind(reference, execution) == :array
        value -> is_list(value)
      end

    {:ok, result, execution}
  end

  @doc "Implements sparse `Array.prototype.concat`."
  def concat(%Call{this: receiver, arguments: arguments, execution: execution}) do
    case array_entries(receiver, execution) do
      {:ok, entries} ->
        entries = Enum.reduce(arguments, entries, &(&2 ++ concat_entries(&1, execution)))
        {array, execution} = from_entries(entries, execution)
        {:ok, array, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  @doc "Implements `Array.prototype.includes` with SameValueZero comparison."
  def includes(%Call{this: receiver, arguments: arguments, execution: execution}) do
    searched = List.first(arguments, :undefined)

    case array_entries(receiver, execution) do
      {:ok, entries} ->
        included? =
          Enum.any?(entries, fn
            :hole -> searched == :undefined
            {:present, :nan} -> searched == :nan
            {:present, value} -> Value.strict_equal?(value, searched)
          end)

        {:ok, included?, execution}

      {:error, reason} ->
        {:error, reason, execution}
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

    case array_entries(receiver, execution) do
      {:ok, entries} ->
        value =
          Enum.map_join(entries, separator, fn
            :hole -> ""
            {:present, value} when value in [nil, :undefined] -> ""
            {:present, value} -> Value.to_string_value(value)
          end)

        {:ok, value, execution}

      {:error, reason} ->
        {:error, reason, execution}
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
            {:ok, execution} = Property.put(array, index, value, execution)
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
    case array_entries(receiver, execution) do
      {:ok, entries} ->
        {start, length} = Value.slice_range(length(entries), arguments)
        {array, execution} = from_entries(Enum.slice(entries, start, length), execution)
        {:ok, array, execution}

      {:error, reason} ->
        {:error, reason, execution}
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

  @doc "Sorts present array values lexicographically when no comparator is supplied."
  def sort(%Call{this: %Reference{} = array, arguments: arguments, execution: execution}) do
    case List.first(arguments, :undefined) do
      :undefined -> sort_default(array, execution)
      _comparator -> {:error, :unsupported_array_sort_comparator, execution}
    end
  end

  def sort(%Call{execution: execution}), do: {:error, :not_an_array, execution}

  @doc "Allocates an owner-local array containing the supplied present values."
  @spec from_values([term()], QuickBEAM.VM.Runtime.State.t()) ::
          {Reference.t(), QuickBEAM.VM.Runtime.State.t()}
  def from_values(values, execution) do
    from_entries(Enum.map(values, &{:present, &1}), execution)
  end

  defp sort_default(array, execution) do
    case array_entries(array, execution) do
      {:ok, entries} ->
        values =
          entries
          |> Enum.flat_map(fn
            {:present, value} -> [value]
            :hole -> []
          end)
          |> Enum.sort_by(&Value.to_string_value/1)

        {:ok, execution} = Heap.update_object(execution, array, &Heap.clear_array/1)

        execution =
          values
          |> Enum.with_index()
          |> Enum.reduce(execution, fn {value, index}, execution ->
            {:ok, execution} = Property.define(array, index, value, execution)
            execution
          end)

        {:ok, array, execution}

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  defp array_entries(value, _execution) when is_list(value),
    do: {:ok, Enum.map(value, &{:present, &1})}

  defp array_entries(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{kind: :array} = object} ->
        {:ok, Heap.array_entries(object)}

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

  @doc "Allocates an owner-local sparse array from present-value and hole entries."
  @spec from_entries([{:present, term()} | :hole], QuickBEAM.VM.Runtime.State.t()) ::
          {Reference.t(), QuickBEAM.VM.Runtime.State.t()}
  def from_entries(entries, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      entries
      |> Enum.with_index()
      |> Enum.reduce(execution, fn
        {{:present, value}, index}, execution ->
          {:ok, execution} = Property.define(array, index, value, execution)
          execution

        {:hole, _index}, execution ->
          execution
      end)

    {:ok, execution} = Property.define(array, "length", length(entries), execution)
    {array, execution}
  end

  defp iteration_action(method, %Call{
         arguments: arguments,
         this: receiver,
         caller: caller,
         tail?: tail?,
         execution: execution
       }) do
    Builtin.action({:array_iteration, method, receiver, arguments, caller, execution, tail?})
  end
end
