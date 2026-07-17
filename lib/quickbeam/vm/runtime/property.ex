defmodule QuickBEAM.VM.Runtime.Property do
  @moduledoc """
  Provides the canonical JavaScript property semantic boundary for the VM.

  Heap references, primitive wrappers, callable pseudo-methods, Promise methods,
  UTF-16 string indices, enumeration, descriptors, and prototype operations all
  pass through this module. Accessor reads return an explicit
  `{:ok, {:accessor, getter, receiver}}` action for the interpreter to resume.
  """

  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference
  alias QuickBEAM.VM.Runtime.Property.Descriptor
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.RegExp
  alias QuickBEAM.VM.Runtime.Value

  @function_tags [
    :builtin,
    :declared_builtin,
    :bound_function,
    :host_function,
    :primitive_method,
    :promise_resolver
  ]

  @type get_result ::
          {:ok, term() | {:accessor, term(), Reference.t()}}
          | {:error, term()}

  @doc "Reads a JavaScript property or returns an accessor invocation action."
  @spec get(term(), term(), State.t()) :: get_result()
  def get(%Reference{} = object, key, execution) do
    case Heap.get(execution, object, key) do
      {:ok, :undefined} = missing ->
        case Heap.fetch_object(execution, object) do
          {:ok, %{internal: :global_object}} ->
            case Map.fetch(execution.globals, key) do
              {:ok, value} -> {:ok, value}
              :error -> missing
            end

          {:ok, %{kind: :regexp}} when key in ["exec", "test"] ->
            {:ok, {:primitive_method, :regexp, key}}

          _other ->
            missing
        end

      result ->
        result
    end
  end

  def get(%PromiseReference{}, key, execution) when is_binary(key),
    do: intrinsic_property(execution, "Promise", key)

  def get(%RegExp{}, key, _execution) when is_binary(key),
    do: {:ok, {:primitive_method, :regexp, key}}

  def get(object, key, execution)
      when is_tuple(object) and is_binary(key) and elem(object, 0) in @function_tags,
      do: intrinsic_property(execution, "Function", key)

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

  def get(object, key, execution) when is_binary(object) and is_binary(key),
    do: intrinsic_property(execution, "String", key)

  def get(object, "length", _execution) when is_list(object), do: {:ok, length(object)}

  def get(object, key, _execution) when is_list(object) and is_integer(key),
    do: {:ok, Enum.at(object, key, :undefined)}

  def get(object, key, execution) when is_list(object) and is_binary(key),
    do: intrinsic_property(execution, "Array", key)

  def get(object, key, execution) when is_number(object) and is_binary(key),
    do: intrinsic_property(execution, "Number", key)

  def get(object, _key, _execution) when object in [nil, :undefined],
    do: {:error, :null_or_undefined_property_access}

  def get(_object, _key, _execution), do: {:ok, :undefined}

  @doc "Writes a JavaScript property or returns an accessor setter action."
  @spec put(term(), term(), term(), State.t()) ::
          {:ok, State.t()} | {:error, term()}
  def put(%Reference{} = object, key, value, execution),
    do: Heap.put(execution, object, key, value)

  def put(object, _key, _value, _execution), do: {:error, {:not_an_object, object}}

  @doc "Defines a data property on an owner-local object."
  @spec define(Reference.t(), term(), term(), State.t(), keyword()) ::
          {:ok, State.t()} | {:error, term()}
  def define(%Reference{} = object, key, value, execution, opts \\ []),
    do: Heap.define(execution, object, key, value, opts)

  @doc "Defines one getter or setter on an owner-local object."
  @spec define_accessor(
          Reference.t(),
          term(),
          :getter | :setter,
          term(),
          State.t(),
          keyword()
        ) ::
          {:ok, State.t()} | {:error, term()}
  def define_accessor(%Reference{} = object, key, kind, callable, execution, opts \\ []),
    do: Heap.define_accessor(execution, object, key, kind, callable, opts)

  @doc "Defines a complete property descriptor on an owner-local object."
  @spec define_descriptor(Reference.t(), term(), Descriptor.t(), State.t()) ::
          {:ok, State.t()} | {:error, term()}
  def define_descriptor(%Reference{} = object, key, %Descriptor{} = property, execution),
    do: Heap.define_descriptor(execution, object, key, property)

  @doc "Deletes an own property according to its configurable flag."
  @spec delete(Reference.t(), term(), State.t()) ::
          {:ok, boolean(), State.t()} | {:error, term()}
  def delete(%Reference{} = object, key, execution), do: Heap.delete(execution, object, key)

  @doc "Returns enumerable own keys in ECMAScript order."
  @spec enumerable_keys(term(), State.t()) :: {:ok, [term()]} | {:error, term()}
  def enumerable_keys(%Reference{} = reference, execution),
    do: Heap.own_keys(execution, reference)

  def enumerable_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  def enumerable_keys([], _execution), do: {:ok, []}

  def enumerable_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  def enumerable_keys(value, _execution) when value in [nil, :undefined], do: {:ok, []}
  def enumerable_keys(_value, _execution), do: {:ok, []}

  @doc "Returns enumerable own string and Symbol keys copied by `Object.assign`."
  @spec assignable_keys(term(), State.t()) :: {:ok, [term()]} | {:error, term()}
  def assignable_keys(%Reference{} = reference, execution),
    do: Heap.assignable_keys(execution, reference)

  def assignable_keys(value, execution), do: enumerable_keys(value, execution)

  @doc "Tests JavaScript property presence across an object's prototype chain."
  @spec has_property?(term(), term(), State.t()) :: boolean()
  def has_property?(%Reference{} = reference, key, execution),
    do: Heap.has_property?(execution, reference, key)

  def has_property?(value, key, _execution) when is_map(value), do: Map.has_key?(value, key)

  def has_property?(value, key, _execution) when is_list(value) and is_integer(key),
    do: key >= 0 and key < length(value)

  def has_property?(value, "length", _execution) when is_list(value) or is_binary(value),
    do: true

  def has_property?(_value, _key, _execution), do: false

  @doc "Returns an object's own descriptor without prototype traversal."
  @spec own_property(Reference.t(), term(), State.t()) ::
          {:ok, Descriptor.t() | nil} | {:error, term()}
  def own_property(%Reference{} = reference, key, execution),
    do: Heap.own_property(execution, reference, key)

  @doc "Returns all own string property names in ECMAScript order."
  @spec own_property_names(Reference.t(), State.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def own_property_names(%Reference{} = reference, execution),
    do: Heap.own_property_names(execution, reference)

  @doc "Returns an object's direct prototype."
  @spec prototype(Reference.t(), State.t()) ::
          {:ok, Reference.t() | nil} | {:error, term()}
  def prototype(%Reference{} = reference, execution), do: Heap.prototype(execution, reference)

  @doc "Updates an object's direct prototype after cycle validation."
  @spec set_prototype(Reference.t(), Reference.t() | nil, State.t()) ::
          {:ok, State.t()} | {:error, term()}
  def set_prototype(%Reference{} = reference, prototype, execution),
    do: Heap.set_prototype(execution, reference, prototype)

  @doc "Tests whether a reference occurs in an object's prototype chain."
  @spec prototype_chain_contains?(Reference.t(), Reference.t(), State.t()) :: boolean()
  def prototype_chain_contains?(%Reference{} = object, %Reference{} = prototype, execution),
    do: Heap.prototype_chain_contains?(execution, object, prototype)

  @doc "Returns the heap kind of an owner-local reference."
  @spec kind(Reference.t(), State.t()) :: QuickBEAM.VM.Runtime.Object.kind() | nil
  def kind(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, object} -> object.kind
      :error -> nil
    end
  end

  defp intrinsic_property(execution, constructor_name, key) do
    with %Reference{} = constructor <- Map.get(execution.globals, constructor_name),
         {:ok, %Reference{} = prototype} <- Heap.get(execution, constructor, "prototype") do
      Heap.get(execution, prototype, key)
    else
      _missing -> {:ok, :undefined}
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
