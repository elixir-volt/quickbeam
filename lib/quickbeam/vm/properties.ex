defmodule QuickBEAM.VM.Properties do
  @moduledoc """
  Provides the canonical JavaScript property semantic boundary for the VM.

  Heap references, primitive wrappers, callable pseudo-methods, Promise methods,
  UTF-16 string indices, enumeration, descriptors, and prototype operations all
  pass through this module. Accessor reads return an explicit
  `{:ok, {:accessor, getter, receiver}}` action for the interpreter to resume.
  """

  alias QuickBEAM.VM.{
    Builtins,
    Execution,
    Heap,
    PromiseReference,
    Property,
    Reference,
    RegExp,
    Value
  }

  @function_tags [
    :builtin,
    :builtin_method,
    :bound_function,
    :function_method,
    :host_function,
    :primitive_method,
    :promise_method,
    :promise_resolver
  ]

  @type get_result ::
          {:ok, term() | {:accessor, term(), Reference.t()}}
          | {:error, term()}

  @doc "Reads a JavaScript property or returns an accessor invocation action."
  @spec get(term(), term(), Execution.t()) :: get_result()
  def get(%Reference{} = object, key, execution) do
    case Heap.get(execution, object, key) do
      {:ok, :undefined} = missing ->
        kind = kind(object, execution)

        cond do
          key in ["bind", "call"] and not is_nil(Builtins.callable(execution, object)) ->
            {:ok, {:function_method, key}}

          kind in [:array, :set] and is_binary(key) ->
            {:ok, {:primitive_method, kind, key}}

          true ->
            missing
        end

      result ->
        result
    end
  end

  def get(%PromiseReference{}, method, _execution)
      when method in ["catch", "finally", "then"],
      do: {:ok, {:promise_method, method}}

  def get(%RegExp{}, key, _execution) when is_binary(key),
    do: {:ok, {:primitive_method, :regexp, key}}

  def get(object, key, _execution)
      when is_tuple(object) and key in ["bind", "call"] and elem(object, 0) in @function_tags,
      do: {:ok, {:function_method, key}}

  def get(object, key, _execution) when is_map(object) and not is_struct(object) do
    case Map.fetch(object, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:ok, map_string_key(object, key)}
    end
  end

  def get(object, "length", _execution) when is_binary(object),
    do: {:ok, Value.string_length(object)}

  def get(object, key, _execution) when is_binary(object) and is_integer(key),
    do: {:ok, Value.string_at(object, key)}

  def get(object, key, _execution) when is_binary(object) and is_binary(key),
    do: {:ok, {:primitive_method, :string, key}}

  def get(object, "length", _execution) when is_list(object), do: {:ok, length(object)}

  def get(object, key, _execution) when is_list(object) and is_integer(key),
    do: {:ok, Enum.at(object, key, :undefined)}

  def get(object, key, _execution) when is_list(object) and is_binary(key),
    do: {:ok, {:primitive_method, :array, key}}

  def get(object, key, _execution) when is_number(object) and is_binary(key),
    do: {:ok, {:primitive_method, :number, key}}

  def get(object, _key, _execution) when object in [nil, :undefined],
    do: {:error, :null_or_undefined_property_access}

  def get(_object, _key, _execution), do: {:ok, :undefined}

  @doc "Writes a JavaScript property or returns an accessor setter action."
  @spec put(term(), term(), term(), Execution.t()) ::
          {:ok, Execution.t()} | {:error, term()}
  def put(%Reference{} = object, key, value, execution),
    do: Heap.put(execution, object, key, value)

  def put(object, _key, _value, _execution), do: {:error, {:not_an_object, object}}

  @doc "Defines a data property on an owner-local object."
  @spec define(Reference.t(), term(), term(), Execution.t(), keyword()) ::
          {:ok, Execution.t()} | {:error, term()}
  def define(%Reference{} = object, key, value, execution, opts \\ []),
    do: Heap.define(execution, object, key, value, opts)

  @doc "Defines one getter or setter on an owner-local object."
  @spec define_accessor(
          Reference.t(),
          term(),
          :getter | :setter,
          term(),
          Execution.t(),
          keyword()
        ) ::
          {:ok, Execution.t()} | {:error, term()}
  def define_accessor(%Reference{} = object, key, kind, callable, execution, opts \\ []),
    do: Heap.define_accessor(execution, object, key, kind, callable, opts)

  @doc "Defines a complete property descriptor on an owner-local object."
  @spec define_descriptor(Reference.t(), term(), Property.t(), Execution.t()) ::
          {:ok, Execution.t()} | {:error, term()}
  def define_descriptor(%Reference{} = object, key, %Property{} = property, execution),
    do: Heap.define_descriptor(execution, object, key, property)

  @doc "Deletes an own property according to its configurable flag."
  @spec delete(Reference.t(), term(), Execution.t()) ::
          {:ok, boolean(), Execution.t()} | {:error, term()}
  def delete(%Reference{} = object, key, execution), do: Heap.delete(execution, object, key)

  @doc "Returns enumerable own keys in ECMAScript order."
  @spec enumerable_keys(term(), Execution.t()) :: {:ok, [term()]} | {:error, term()}
  def enumerable_keys(%Reference{} = reference, execution),
    do: Heap.own_keys(execution, reference)

  def enumerable_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  def enumerable_keys([], _execution), do: {:ok, []}

  def enumerable_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  def enumerable_keys(value, _execution) when value in [nil, :undefined], do: {:ok, []}
  def enumerable_keys(_value, _execution), do: {:ok, []}

  @doc "Tests JavaScript property presence across an object's prototype chain."
  @spec has_property?(term(), term(), Execution.t()) :: boolean()
  def has_property?(%Reference{} = reference, key, execution),
    do: Heap.has_property?(execution, reference, key)

  def has_property?(value, key, _execution) when is_map(value), do: Map.has_key?(value, key)

  def has_property?(value, key, _execution) when is_list(value) and is_integer(key),
    do: key >= 0 and key < length(value)

  def has_property?(value, "length", _execution) when is_list(value) or is_binary(value),
    do: true

  def has_property?(_value, _key, _execution), do: false

  @doc "Returns an object's own descriptor without prototype traversal."
  @spec own_property(Reference.t(), term(), Execution.t()) ::
          {:ok, Property.t() | nil} | {:error, term()}
  def own_property(%Reference{} = reference, key, execution),
    do: Heap.own_property(execution, reference, key)

  @doc "Returns all own string property names in ECMAScript order."
  @spec own_property_names(Reference.t(), Execution.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def own_property_names(%Reference{} = reference, execution),
    do: Heap.own_property_names(execution, reference)

  @doc "Returns an object's direct prototype."
  @spec prototype(Reference.t(), Execution.t()) ::
          {:ok, Reference.t() | nil} | {:error, term()}
  def prototype(%Reference{} = reference, execution), do: Heap.prototype(execution, reference)

  @doc "Updates an object's direct prototype after cycle validation."
  @spec set_prototype(Reference.t(), Reference.t() | nil, Execution.t()) ::
          {:ok, Execution.t()} | {:error, term()}
  def set_prototype(%Reference{} = reference, prototype, execution),
    do: Heap.set_prototype(execution, reference, prototype)

  @doc "Tests whether a reference occurs in an object's prototype chain."
  @spec prototype_chain_contains?(Reference.t(), Reference.t(), Execution.t()) :: boolean()
  def prototype_chain_contains?(%Reference{} = object, %Reference{} = prototype, execution),
    do: Heap.prototype_chain_contains?(execution, object, prototype)

  @doc "Returns the heap kind of an owner-local reference."
  @spec kind(Reference.t(), Execution.t()) :: QuickBEAM.VM.Object.kind() | nil
  def kind(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, object} -> object.kind
      :error -> nil
    end
  end

  defp map_string_key(map, key) when is_binary(key) do
    case Enum.find(map, fn
           {map_key, _value} when is_atom(map_key) -> Atom.to_string(map_key) == key
           _entry -> false
         end) do
      {_map_key, value} -> value
      nil -> :undefined
    end
  end

  defp map_string_key(_map, _key), do: :undefined
end
