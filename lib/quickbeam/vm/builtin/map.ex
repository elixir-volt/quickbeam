defmodule QuickBEAM.VM.Builtin.Map do
  @moduledoc "Defines the declarative Map constructor and core methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call

  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Iterator
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.Symbol
  alias QuickBEAM.VM.Runtime.Value

  builtin "Map",
    kind: :constructor,
    constructor: :construct,
    length: 0,
    depends_on: ["Object", "Function", "Symbol"] do
    prototype do
      method :clear, length: 0
      method :delete, length: 1
      method :entries, length: 0
      method :get, length: 1
      method :has, length: 1
      method :keys, length: 0
      method :set, length: 2
      getter :size
      method :values, length: 0
      prototype_alias(Symbol.iterator(), to: "entries")
    end
  end

  @doc "Constructs a Map from an array-like iterable of key-value pairs."
  def construct(%Call{
        this: %Reference{} = receiver,
        caller: %Boundary.Constructor{},
        arguments: arguments,
        execution: execution
      }) do
    iterable = List.first(arguments, :undefined)

    with {:ok, entries} <- constructor_entries(iterable, execution),
         {:ok, execution} <- initialize(receiver, entries, execution) do
      {:ok, receiver, execution}
    else
      {:error, reason} -> {:error, reason, execution}
      {:resumable} -> {:error, :unsupported_map_iterable, execution}
    end
  end

  def construct(%Call{execution: execution}),
    do: {:error, :map_constructor_requires_new, execution}

  @doc "Removes every entry from a Map."
  def clear(%Call{this: %Reference{} = map, execution: execution}) do
    update_map(map, execution, fn _entries -> [] end, :undefined)
  end

  def clear(%Call{execution: execution}), do: incompatible(execution)

  @doc "Removes an entry and reports whether it existed."
  def delete(%Call{this: %Reference{} = map, arguments: arguments, execution: execution}) do
    key = List.first(arguments, :undefined)

    with {:ok, entries} <- entries(map, execution) do
      found? = Enum.any?(entries, fn {candidate, _value} -> same_key?(candidate, key) end)
      retained = Enum.reject(entries, fn {candidate, _value} -> same_key?(candidate, key) end)
      update_map(map, execution, fn _entries -> retained end, found?)
    else
      :error -> incompatible(execution)
    end
  end

  def delete(%Call{execution: execution}), do: incompatible(execution)

  @doc "Creates an insertion-ordered Map entry iterator."
  def entries(%Call{} = call), do: map_iterator(call, :entries)

  @doc "Returns a Map value or undefined when the key is absent."
  def get(%Call{this: %Reference{} = map, arguments: arguments, execution: execution}) do
    key = List.first(arguments, :undefined)

    case entries(map, execution) do
      {:ok, entries} ->
        value =
          Enum.find_value(entries, :undefined, fn {candidate, value} ->
            if same_key?(candidate, key), do: {:found, value}
          end)

        value =
          case value do
            {:found, found} -> found
            other -> other
          end

        {:ok, value, execution}

      :error ->
        incompatible(execution)
    end
  end

  def get(%Call{execution: execution}), do: incompatible(execution)

  @doc "Tests whether a Map contains a key."
  def has(%Call{this: %Reference{} = map, arguments: arguments, execution: execution}) do
    key = List.first(arguments, :undefined)

    case entries(map, execution) do
      {:ok, entries} ->
        {:ok, Enum.any?(entries, fn {candidate, _value} -> same_key?(candidate, key) end),
         execution}

      :error ->
        incompatible(execution)
    end
  end

  def has(%Call{execution: execution}), do: incompatible(execution)

  @doc "Creates an insertion-ordered Map key iterator."
  def keys(%Call{} = call), do: map_iterator(call, :keys)

  @doc "Adds or replaces a Map entry while preserving insertion order."
  def set(%Call{this: %Reference{} = map, arguments: arguments, execution: execution}) do
    key = Enum.at(arguments, 0, :undefined)
    value = Enum.at(arguments, 1, :undefined)

    update_map(
      map,
      execution,
      fn entries ->
        case Enum.find_index(entries, fn {candidate, _value} -> same_key?(candidate, key) end) do
          nil -> entries ++ [{key, value}]
          index -> List.replace_at(entries, index, {key, value})
        end
      end,
      map
    )
  end

  def set(%Call{execution: execution}), do: incompatible(execution)

  @doc "Returns the next result from an internal Map iterator."
  def next(%Call{this: %Reference{} = iterator, execution: execution}) do
    case Heap.fetch_object(execution, iterator) do
      {:ok, %Object{internal: {:map_iterator, entries, index, kind}}} ->
        done? = index >= length(entries)

        {value, execution} =
          if done? do
            {:undefined, execution}
          else
            {key, value} = Enum.at(entries, index)

            case kind do
              :keys -> {key, execution}
              :values -> {value, execution}
              :entries -> map_entry_array(key, value, execution)
            end
          end

        {:ok, execution} =
          Heap.update_object(execution, iterator, fn object ->
            %{
              object
              | internal: {:map_iterator, entries, if(done?, do: index, else: index + 1), kind}
            }
          end)

        {result, execution} = Heap.allocate(execution)
        {:ok, execution} = Property.define(result, "value", value, execution)
        {:ok, execution} = Property.define(result, "done", done?, execution)
        {:ok, result, execution}

      _other ->
        {:error, :incompatible_map_iterator_receiver, execution}
    end
  end

  def next(%Call{execution: execution}),
    do: {:error, :incompatible_map_iterator_receiver, execution}

  @doc "Returns the number of entries in a Map."
  def size(%Call{this: %Reference{} = map, execution: execution}) do
    case entries(map, execution) do
      {:ok, entries} -> {:ok, length(entries), execution}
      :error -> incompatible(execution)
    end
  end

  def size(%Call{execution: execution}), do: incompatible(execution)

  @doc "Creates an insertion-ordered Map value iterator."
  def values(%Call{} = call), do: map_iterator(call, :values)

  @doc "Initializes a Map receiver from insertion-ordered entries."
  def initialize(receiver, entries, execution) do
    entries =
      Enum.reduce(entries, [], fn {key, value}, accumulated ->
        case Enum.find_index(accumulated, fn {candidate, _value} -> same_key?(candidate, key) end) do
          nil -> accumulated ++ [{key, value}]
          index -> List.replace_at(accumulated, index, {key, value})
        end
      end)

    Heap.update_object(execution, receiver, fn object ->
      %{object | kind: :map, internal: %{entries: entries}}
    end)
  end

  defp constructor_entries(iterable, _execution) when iterable in [:undefined, nil], do: {:ok, []}

  defp constructor_entries(%Reference{} = iterable, execution) do
    case entries(iterable, execution) do
      {:ok, entries} -> {:ok, entries}
      :error -> iterable |> Iterator.values(execution) |> pair_entries(execution)
    end
  end

  defp constructor_entries(iterable, execution),
    do: iterable |> Iterator.values(execution) |> pair_entries(execution)

  defp pair_entries({:ok, values}, execution) do
    Enum.reduce_while(values, {:ok, []}, fn pair, {:ok, entries} ->
      with {:ok, key} <- Property.get(pair, 0, execution),
           {:ok, value} <- Property.get(pair, 1, execution) do
        {:cont, {:ok, entries ++ [{key, value}]}}
      else
        _error -> {:halt, {:error, :invalid_map_entry}}
      end
    end)
  end

  defp pair_entries(other, _execution), do: other

  defp map_iterator(%Call{this: %Reference{} = map, execution: execution}, kind) do
    case entries(map, execution) do
      {:ok, entries} ->
        {iterator, execution} =
          Heap.allocate(execution, :ordinary, internal: {:map_iterator, entries, 0, kind})

        {next, execution} = Heap.allocate(execution, :function, callable: declared(:next))
        {:ok, execution} = Property.define(iterator, "next", next, execution)
        {:ok, iterator, execution}

      :error ->
        incompatible(execution)
    end
  end

  defp map_iterator(%Call{execution: execution}, _kind), do: incompatible(execution)

  defp map_entry_array(key, value, execution) do
    {entry, execution} = Heap.allocate(execution, :array)
    {:ok, execution} = Property.define(entry, 0, key, execution)
    {:ok, execution} = Property.define(entry, 1, value, execution)
    {entry, execution}
  end

  defp entries(map, execution) do
    case Heap.fetch_object(execution, map) do
      {:ok, %Object{kind: :map, internal: %{entries: entries}}} -> {:ok, entries}
      _other -> :error
    end
  end

  defp update_map(map, execution, update, result) do
    case Heap.update_object(execution, map, fn
           %Object{kind: :map, internal: %{entries: entries}} = object ->
             %{object | internal: %{entries: update.(entries)}}

           object ->
             object
         end) do
      {:ok, execution} ->
        case entries(map, execution) do
          {:ok, _entries} -> {:ok, result, execution}
          :error -> incompatible(execution)
        end

      {:error, _reason} ->
        incompatible(execution)
    end
  end

  defp same_key?(:nan, :nan), do: true
  defp same_key?(left, right), do: Value.strict_equal?(left, right)

  defp declared(handler), do: {:declared_builtin, __MODULE__, handler}
  defp incompatible(execution), do: {:error, :incompatible_map_receiver, execution}
end
