defmodule QuickBEAM.VM.Builtins.Set do
  @moduledoc "Defines the declarative Set constructor, methods, and iterator alias."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin
  alias QuickBEAM.VM.Builtin.Call

  alias QuickBEAM.VM.{
    ConstructorBoundary,
    Heap,
    Iterator,
    Object,
    Properties,
    Reference,
    Symbol,
    Value
  }

  builtin "Set",
    kind: :constructor,
    constructor: :construct,
    length: 0,
    depends_on: ["Object", "Function", "Symbol"] do
    prototype do
      method :add, length: 1
      method :delete, length: 1
      method :has, length: 1
      method :values, length: 0
      getter :size
      prototype_alias(Symbol.iterator(), to: "values")
    end
  end

  @doc "Constructs an insertion-ordered Set from a supported iterable."
  def construct(
        %Call{
          this: %Reference{} = receiver,
          caller: %ConstructorBoundary{},
          arguments: arguments,
          execution: execution
        } = call
      ) do
    iterable = List.first(arguments, :undefined)

    case constructor_values(iterable, execution) do
      {:ok, values} ->
        case initialize(receiver, values, execution) do
          {:ok, execution} -> {:ok, receiver, execution}
          {:error, reason} -> {:error, reason, execution}
        end

      {:resumable} ->
        Builtin.action({:set_iterate, receiver, iterable, call.caller, execution, call.tail?})

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def construct(%Call{execution: execution}),
    do: {:error, :set_constructor_requires_new, execution}

  @doc "Adds a value while preserving Set insertion order."
  def add(%Call{this: %Reference{} = set, arguments: arguments, execution: execution}) do
    value = List.first(arguments, :undefined)

    case Heap.update_object(execution, set, fn
           %Object{kind: :set, internal: %{values: values, index: index}} = object ->
             if MapSet.member?(index, value) do
               object
             else
               %{object | internal: %{values: values ++ [value], index: MapSet.put(index, value)}}
             end

           object ->
             object
         end) do
      {:ok, execution} ->
        case Heap.fetch_object(execution, set) do
          {:ok, %Object{kind: :set}} -> {:ok, set, execution}
          _other -> {:error, :incompatible_set_receiver, execution}
        end

      {:error, reason} ->
        {:error, reason, execution}
    end
  end

  def add(%Call{execution: execution}), do: {:error, :incompatible_set_receiver, execution}

  @doc "Removes a value and reports whether it was present."
  def delete(%Call{this: %Reference{} = set, arguments: arguments, execution: execution}) do
    value = List.first(arguments, :undefined)

    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: %{values: values, index: index}}} ->
        found? = MapSet.member?(index, value)

        {:ok, execution} =
          Heap.update_object(execution, set, fn object ->
            %{
              object
              | internal: %{
                  values: Enum.reject(values, &Value.strict_equal?(&1, value)),
                  index: MapSet.delete(index, value)
                }
            }
          end)

        {:ok, found?, execution}

      _other ->
        {:error, :incompatible_set_receiver, execution}
    end
  end

  def delete(%Call{execution: execution}), do: {:error, :incompatible_set_receiver, execution}

  @doc "Tests membership in a Set."
  def has(%Call{this: %Reference{} = set, arguments: arguments, execution: execution}) do
    value = List.first(arguments, :undefined)

    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: %{index: entries}}} ->
        {:ok, MapSet.member?(entries, value), execution}

      _other ->
        {:error, :incompatible_set_receiver, execution}
    end
  end

  def has(%Call{execution: execution}), do: {:error, :incompatible_set_receiver, execution}

  @doc "Returns the number of unique Set entries."
  def size(%Call{this: %Reference{} = set, execution: execution}) do
    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: %{values: values}}} ->
        {:ok, length(values), execution}

      _other ->
        {:error, :incompatible_set_receiver, execution}
    end
  end

  def size(%Call{execution: execution}), do: {:error, :incompatible_set_receiver, execution}

  @doc "Creates an insertion-ordered Set value iterator."
  def values(%Call{this: %Reference{} = set, execution: execution}) do
    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: %{values: values}}} ->
        {iterator, execution} =
          Heap.allocate(execution, :ordinary, internal: {:set_iterator, values, 0})

        {next, execution} = Heap.allocate(execution, :function, callable: declared(:next))

        {:ok, execution} =
          Properties.define(next, "name", "next", execution,
            writable: false,
            enumerable: false,
            configurable: true
          )

        {:ok, execution} =
          Properties.define(next, "length", 0, execution,
            writable: false,
            enumerable: false,
            configurable: true
          )

        {:ok, execution} =
          Properties.define(iterator, "next", next, execution,
            writable: true,
            enumerable: false,
            configurable: true
          )

        {:ok, iterator, execution}

      _other ->
        {:error, :incompatible_set_receiver, execution}
    end
  end

  def values(%Call{execution: execution}), do: {:error, :incompatible_set_receiver, execution}

  @doc "Advances one Set value iterator."
  def next(%Call{this: %Reference{} = iterator, execution: execution}) do
    case Heap.fetch_object(execution, iterator) do
      {:ok, %Object{internal: {:set_iterator, values, index}}} ->
        done? = index >= length(values)
        value = if done?, do: :undefined, else: Enum.at(values, index)

        {:ok, execution} =
          Heap.update_object(execution, iterator, fn object ->
            %{object | internal: {:set_iterator, values, if(done?, do: index, else: index + 1)}}
          end)

        {result, execution} = Heap.allocate(execution)
        {:ok, execution} = Properties.define(result, "value", value, execution)
        {:ok, execution} = Properties.define(result, "done", done?, execution)
        {:ok, result, execution}

      _other ->
        {:error, :incompatible_set_iterator_receiver, execution}
    end
  end

  def next(%Call{execution: execution}),
    do: {:error, :incompatible_set_iterator_receiver, execution}

  defp constructor_values(iterable, _execution) when iterable in [:undefined, nil], do: {:ok, []}

  defp constructor_values(iterable, execution), do: Iterator.values(iterable, execution)

  @doc "Initializes a Set receiver from values in iteration order."
  def initialize(receiver, values, execution) do
    values = Enum.uniq(values)

    Heap.update_object(execution, receiver, fn object ->
      %{object | kind: :set, internal: %{values: values, index: MapSet.new(values)}}
    end)
  end

  defp declared(handler), do: {:declared_builtin, __MODULE__, handler}
end
