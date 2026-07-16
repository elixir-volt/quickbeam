defmodule QuickBEAM.VM.Heap do
  @moduledoc """
  Manages objects and properties in an evaluation's process-owned heap.

  Live references are valid only with the `QuickBEAM.VM.Execution` that owns
  them and are exported to ordinary BEAM values at the evaluation boundary.
  """

  alias QuickBEAM.VM.{Execution, Memory, Object, Property, Reference}

  @max_prototype_depth 1_000

  @spec allocate(Execution.t(), Object.kind(), keyword()) :: {Reference.t(), Execution.t()}
  def allocate(execution, kind \\ :ordinary, opts \\ [])

  def allocate(%Execution{} = execution, kind, []) do
    object = %Object{kind: kind, prototype: Map.get(execution.default_prototypes, kind)}
    store_new_object(execution, object)
  end

  def allocate(%Execution{} = execution, kind, opts) do
    prototype =
      case Keyword.fetch(opts, :prototype) do
        {:ok, prototype} -> prototype
        :error -> Map.get(execution.default_prototypes, kind)
      end

    object = %Object{
      kind: kind,
      prototype: prototype,
      length: Keyword.get(opts, :length, 0),
      callable: Keyword.get(opts, :callable),
      internal: Keyword.get(opts, :internal)
    }

    store_new_object(execution, object)
  end

  @doc "Allocates a dense array in one heap update with canonical default descriptors."
  @spec allocate_array(Execution.t(), [term()]) :: {Reference.t(), Execution.t()}
  def allocate_array(%Execution{} = execution, values) when is_list(values) do
    object = %Object{
      kind: :array,
      prototype: Map.get(execution.default_prototypes, :array),
      length: length(values),
      properties:
        values
        |> Enum.with_index()
        |> Map.new(fn {value, index} -> {index, {value}} end)
    }

    empty_object = %{object | length: 0, properties: %{}}

    execution =
      Enum.reduce(Enum.with_index(values), Memory.charge_object(execution, empty_object), fn
        {value, index}, execution -> Memory.charge_property(execution, index, value)
      end)

    store_precharged_object(execution, object)
  end

  defp store_new_object(execution, object) do
    execution
    |> Memory.charge_object(object)
    |> store_precharged_object(object)
  end

  defp store_precharged_object(execution, object) do
    id = execution.next_object_id
    reference = %Reference{id: id}
    execution = %{execution | heap: Map.put(execution.heap, id, object), next_object_id: id + 1}
    {reference, execution}
  end

  @doc "Returns enumerable own string and Symbol keys in ECMAScript order."
  @spec assignable_keys(Execution.t(), Reference.t()) :: {:ok, [term()]} | {:error, term()}
  def assignable_keys(execution, %Reference{id: id} = reference) do
    case fetch_object(execution, reference) do
      {:ok, object} ->
        integer_keys =
          object.properties
          |> Enum.filter(fn {key, property} ->
            is_integer(key) and property_enumerable?(property)
          end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        other_keys =
          Enum.filter(object.property_order, fn key ->
            not is_integer(key) and property_enumerable?(object.properties[key])
          end)

        {:ok, integer_keys ++ other_keys}

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  @spec fetch_object(Execution.t(), Reference.t()) :: {:ok, Object.t()} | :error
  def fetch_object(%Execution{} = execution, %Reference{id: id}),
    do: Map.fetch(execution.heap, id)

  @doc "Returns sparse entries for one canonical array object."
  @spec array_entries(Object.t()) :: [:hole | {:present, term()}]
  def array_entries(%Object{kind: :array, length: 0}), do: []

  def array_entries(%Object{kind: :array, length: length, properties: properties}) do
    Enum.map(0..(length - 1), fn index ->
      case Map.get(properties, index) do
        {value} -> {:present, value}
        %Property{value: value} -> {:present, value}
        nil -> :hole
      end
    end)
  end

  @doc "Clears indexed array elements while retaining non-index properties."
  @spec clear_array(Object.t()) :: Object.t()
  def clear_array(%Object{kind: :array} = object) do
    properties = Map.reject(object.properties, fn {key, _property} -> is_integer(key) end)
    %{object | properties: properties, length: 0}
  end

  @spec get(Execution.t(), Reference.t(), term()) :: {:ok, term()} | {:error, term()}
  def get(%Execution{} = execution, %Reference{} = reference, key) do
    get_with_depth(execution, reference, normalize_key(key), reference, 0)
  end

  @spec has_property?(Execution.t(), Reference.t(), term()) :: boolean()
  def has_property?(execution, %Reference{} = reference, key) do
    key = normalize_key(key)

    case fetch_object(execution, reference) do
      {:ok, %Object{kind: :array}} when key == "length" ->
        true

      {:ok, object} ->
        Map.has_key?(object.properties, key) or
          (is_struct(object.prototype, Reference) and
             has_property?(execution, object.prototype, key))

      :error ->
        false
    end
  end

  @spec put(Execution.t(), Reference.t(), term(), term()) ::
          {:ok, Execution.t()} | {:error, term()}
  def put(%Execution{} = execution, %Reference{id: id} = reference, key, value) do
    key = normalize_key(key)

    case fetch_object(execution, reference) do
      {:ok, %Object{kind: :array} = object} when is_integer(key) ->
        case Map.get(object.properties, key) do
          {_old_value} -> store_default_array_index(execution, id, object, key, value, true)
          nil -> put_new_default_array_index(execution, id, object, key, value)
          %Property{} -> put_object(execution, id, object, key, value)
        end

      {:ok, object} ->
        put_object(execution, id, object, key, value)

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  @spec define(Execution.t(), Reference.t(), term(), term(), keyword()) ::
          {:ok, Execution.t()} | {:error, term()}
  def define(%Execution{} = execution, %Reference{id: id} = reference, key, value, opts \\ []) do
    key = normalize_key(key)

    case fetch_object(execution, reference) do
      {:ok, %Object{kind: :array} = object} when is_integer(key) ->
        case {Map.get(object.properties, key), default_property_options?(opts)} do
          {{_old_value}, true} ->
            store_default_array_index(execution, id, object, key, value, true)

          {nil, true} ->
            define_new_default_array_index(execution, id, object, key, value)

          {_property, _default?} ->
            define_object(execution, id, object, key, value, opts)
        end

      {:ok, object} ->
        define_object(execution, id, object, key, value, opts)

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  @doc "Returns an object's own property descriptor without traversing its prototype."
  @spec own_property(Execution.t(), Reference.t(), term()) ::
          {:ok, Property.t() | nil} | {:error, term()}
  def own_property(execution, %Reference{id: id} = reference, key) do
    key = normalize_key(key)

    case fetch_object(execution, reference) do
      {:ok, %Object{kind: :array} = object} when key == "length" ->
        {:ok,
         %Property{
           value: object.length,
           writable: object.length_writable,
           enumerable: false,
           configurable: false
         }}

      {:ok, object} ->
        {:ok, object |> own_property_value(key) |> Object.property_descriptor()}

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  @doc "Replaces an object's prototype after validating the owner-local chain."
  @spec set_prototype(Execution.t(), Reference.t(), Reference.t() | nil) ::
          {:ok, Execution.t()} | {:error, term()}
  def set_prototype(execution, %Reference{id: id} = reference, prototype)
      when is_nil(prototype) or is_struct(prototype, Reference) do
    with {:ok, object} <- fetch_object(execution, reference),
         :ok <- valid_prototype?(execution, reference, prototype) do
      object = %{object | prototype: prototype}
      {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
    else
      :error -> {:error, {:invalid_reference, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Tests whether a reference appears in an object's prototype chain."
  @spec prototype_chain_contains?(Execution.t(), Reference.t(), Reference.t()) :: boolean()
  def prototype_chain_contains?(execution, %Reference{} = object, %Reference{} = prototype) do
    case fetch_object(execution, object) do
      {:ok, object} -> prototype_contains?(execution, object.prototype, prototype, 0)
      :error -> false
    end
  end

  @doc "Returns an object's direct prototype."
  @spec prototype(Execution.t(), Reference.t()) ::
          {:ok, Reference.t() | nil} | {:error, term()}
  def prototype(execution, %Reference{id: id} = reference) do
    case fetch_object(execution, reference) do
      {:ok, object} -> {:ok, object.prototype}
      :error -> {:error, {:invalid_reference, id}}
    end
  end

  @doc "Defines or updates an accessor property on an owner-local object."
  @spec define_accessor(
          Execution.t(),
          Reference.t(),
          term(),
          :getter | :setter,
          term(),
          keyword()
        ) :: {:ok, Execution.t()} | {:error, term()}
  def define_accessor(execution, %Reference{id: id} = reference, key, kind, callable, opts \\ [])
      when kind in [:getter, :setter] do
    key = normalize_key(key)

    with {:ok, object} <- fetch_object(execution, reference) do
      current = own_property_value(object, key)

      property = %Property{
        kind: :accessor,
        value: :undefined,
        writable: false,
        enumerable: Keyword.get(opts, :enumerable, current_flag(current, :enumerable, true)),
        configurable:
          Keyword.get(opts, :configurable, current_flag(current, :configurable, true)),
        getter: if(kind == :getter, do: callable, else: current_accessor(current, :getter)),
        setter: if(kind == :setter, do: callable, else: current_accessor(current, :setter))
      }

      store_descriptor(execution, id, object, key, property)
    else
      :error -> {:error, {:invalid_reference, id}}
    end
  end

  @doc "Defines a complete data or accessor descriptor on an owner-local object."
  @spec define_descriptor(Execution.t(), Reference.t(), term(), Property.t()) ::
          {:ok, Execution.t()} | {:error, term()}
  def define_descriptor(execution, %Reference{id: id} = reference, key, %Property{} = property) do
    key = normalize_key(key)

    with {:ok, object} <- fetch_object(execution, reference) do
      if object.kind == :array and key == "length",
        do: {:error, {:property_not_configurable, "length"}},
        else: store_descriptor(execution, id, object, key, property)
    else
      :error -> {:error, {:invalid_reference, id}}
    end
  end

  @spec delete(Execution.t(), Reference.t(), term()) ::
          {:ok, boolean(), Execution.t()} | {:error, term()}
  def delete(%Execution{} = execution, %Reference{id: id} = reference, key) do
    key = normalize_key(key)

    case fetch_object(execution, reference) do
      {:ok, object} ->
        case Map.get(object.properties, key) do
          %Property{configurable: false} ->
            {:ok, false, execution}

          _property ->
            object = %{
              object
              | properties: Map.delete(object.properties, key),
                property_order: List.delete(object.property_order, key)
            }

            {:ok, true, %{execution | heap: Map.put(execution.heap, id, object)}}
        end

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  @spec update_object(Execution.t(), Reference.t(), (Object.t() -> Object.t())) ::
          {:ok, Execution.t()} | {:error, term()}
  def update_object(%Execution{} = execution, %Reference{id: id} = reference, update) do
    case fetch_object(execution, reference) do
      {:ok, object} -> {:ok, %{execution | heap: Map.put(execution.heap, id, update.(object))}}
      :error -> {:error, {:invalid_reference, id}}
    end
  end

  @doc "Returns all own string property names in ECMAScript key order."
  @spec own_property_names(Execution.t(), Reference.t()) ::
          {:ok, [String.t()]} | {:error, term()}
  def own_property_names(execution, %Reference{id: id} = reference) do
    case fetch_object(execution, reference) do
      {:ok, object} ->
        integer_keys =
          object.properties
          |> Map.keys()
          |> Enum.filter(&is_integer/1)
          |> Enum.sort()
          |> Enum.map(&Integer.to_string/1)

        string_keys = Enum.filter(object.property_order, &is_binary/1)
        builtins = if object.kind == :array, do: ["length"], else: []
        {:ok, integer_keys ++ builtins ++ string_keys}

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  @spec own_keys(Execution.t(), Reference.t()) :: {:ok, [term()]} | {:error, term()}
  def own_keys(execution, %Reference{id: id} = reference) do
    case fetch_object(execution, reference) do
      {:ok, object} ->
        integer_keys =
          object.properties
          |> Enum.filter(fn {key, property} ->
            is_integer(key) and property_enumerable?(property)
          end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        string_keys =
          Enum.filter(object.property_order, fn key ->
            is_binary(key) and property_enumerable?(object.properties[key])
          end)

        {:ok, integer_keys ++ string_keys}

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  defp valid_prototype?(_execution, _reference, nil), do: :ok

  defp valid_prototype?(execution, reference, prototype) do
    case prototype_contains?(execution, prototype, reference, 0) do
      true -> {:error, :cyclic_prototype}
      false -> :ok
    end
  end

  defp prototype_contains?(_execution, nil, _reference, _depth), do: false

  defp prototype_contains?(_execution, _prototype, _reference, depth)
       when depth > @max_prototype_depth,
       do: true

  defp prototype_contains?(_execution, prototype, reference, _depth)
       when prototype.id == reference.id,
       do: true

  defp prototype_contains?(execution, prototype, reference, depth) do
    case fetch_object(execution, prototype) do
      {:ok, object} -> prototype_contains?(execution, object.prototype, reference, depth + 1)
      :error -> false
    end
  end

  defp get_with_depth(_execution, _reference, _key, _receiver, depth)
       when depth > @max_prototype_depth,
       do: {:error, :prototype_chain_too_deep}

  defp get_with_depth(execution, %Reference{id: id} = reference, key, receiver, depth) do
    case fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length}} when key == "length" ->
        {:ok, length}

      {:ok, object} ->
        case Map.fetch(object.properties, key) do
          {:ok, {value}} ->
            {:ok, value}

          {:ok, %Property{getter: getter}} when not is_nil(getter) ->
            {:ok, {:accessor, getter, receiver}}

          {:ok, %Property{setter: setter}} when not is_nil(setter) ->
            {:ok, :undefined}

          {:ok, %Property{value: value}} ->
            {:ok, value}

          :error when is_struct(object.prototype, Reference) ->
            get_with_depth(execution, object.prototype, key, receiver, depth + 1)

          :error ->
            {:ok, :undefined}
        end

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  defp put_object(execution, id, object, key, value) do
    case put_value(execution, object, key, value) do
      {:ok, object} ->
        execution = maybe_charge_property(execution, object, key, value)
        updated = put_property(object, key, value)
        {:ok, %{execution | heap: Map.put(execution.heap, id, updated)}}

      {:error, reason} ->
        {:error, reason}

      {:array_length, object} ->
        {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
    end
  end

  defp define_object(execution, id, object, key, value, opts) do
    case define_property(object, key, value, opts) do
      {:ok, object, property} ->
        execution = maybe_charge_property(execution, object, key, value)
        object = put_property_struct(object, key, property)
        {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}

      {:error, reason} ->
        {:error, reason}

      {:array_length, object} ->
        {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
    end
  end

  defp put_new_default_array_index(execution, id, object, key, value) do
    inherited = inherited_property(execution, object.prototype, key, 0)

    cond do
      match?(%Property{setter: setter} when not is_nil(setter), inherited) ->
        {:error, {:invoke_setter, inherited.setter}}

      accessor?(inherited) or match?(%Property{writable: false}, inherited) ->
        {:error, {:property_not_writable, key}}

      key >= object.length and not object.length_writable ->
        {:error, {:property_not_writable, "length"}}

      not object.extensible ->
        {:error, {:object_not_extensible, key}}

      true ->
        store_default_array_index(execution, id, object, key, value, false)
    end
  end

  defp define_new_default_array_index(execution, id, object, key, value) do
    cond do
      not object.extensible ->
        {:error, {:object_not_extensible, key}}

      key >= object.length and not object.length_writable ->
        {:error, {:property_not_writable, "length"}}

      true ->
        store_default_array_index(execution, id, object, key, value, false)
    end
  end

  defp store_default_array_index(execution, id, object, key, value, present?) do
    execution = if present?, do: execution, else: Memory.charge_property(execution, key, value)

    object = %{
      object
      | properties: Map.put(object.properties, key, {value}),
        length: max(object.length, key + 1)
    }

    {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
  end

  defp default_property_options?(opts) do
    Keyword.get(opts, :writable, true) and Keyword.get(opts, :enumerable, true) and
      Keyword.get(opts, :configurable, true)
  end

  defp maybe_charge_property(execution, object, key, value) do
    if Map.has_key?(object.properties, key),
      do: execution,
      else: Memory.charge_property(execution, key, value)
  end

  defp put_value(_execution, %Object{kind: :array} = object, "length", value) do
    with :ok <- array_length_writable(object),
         {:ok, length} <- array_length(value),
         {:ok, object} <- resize_array(object, length) do
      {:array_length, object}
    end
  end

  defp put_value(execution, object, key, _value) do
    descriptor =
      own_property_value(object, key) || inherited_property(execution, object.prototype, key, 0)

    cond do
      match?(%Property{setter: setter} when not is_nil(setter), descriptor) ->
        {:error, {:invoke_setter, descriptor.setter}}

      accessor?(descriptor) ->
        {:error, {:property_not_writable, key}}

      match?(%Property{writable: false}, descriptor) ->
        {:error, {:property_not_writable, key}}

      Map.has_key?(object.properties, key) ->
        {:ok, object}

      object.kind == :array and is_integer(key) and key >= object.length and
          not object.length_writable ->
        {:error, {:property_not_writable, "length"}}

      object.extensible ->
        {:ok, object}

      true ->
        {:error, {:object_not_extensible, key}}
    end
  end

  defp define_property(%Object{kind: :array} = object, "length", value, opts) do
    cond do
      Keyword.get(opts, :configurable, false) ->
        {:error, {:property_not_configurable, "length"}}

      Keyword.get(opts, :enumerable, false) ->
        {:error, {:property_not_configurable, "length"}}

      true ->
        with :ok <- array_length_writable(object),
             {:ok, length} <- array_length(value),
             {:ok, object} <- resize_array(object, length) do
          writable = Keyword.get(opts, :writable, object.length_writable)
          {:array_length, %{object | length_writable: writable}}
        end
    end
  end

  defp define_property(object, key, value, opts) do
    property = property(value, opts)

    case validate_definition(object, key, property) do
      {:ok, object} -> {:ok, object, property}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_definition(object, key, candidate) do
    case own_property_value(object, key) do
      %Property{configurable: false} = current ->
        cond do
          candidate.configurable ->
            {:error, {:property_not_configurable, key}}

          property_enumerable?(candidate) != property_enumerable?(current) ->
            {:error, {:property_not_configurable, key}}

          accessor?(candidate) != accessor?(current) ->
            {:error, {:property_not_configurable, key}}

          accessor?(current) and
              (candidate.getter != current.getter or candidate.setter != current.setter) ->
            {:error, {:property_not_configurable, key}}

          not accessor?(current) and not current.writable and candidate.writable ->
            {:error, {:property_not_writable, key}}

          not accessor?(current) and not current.writable and candidate.value != current.value ->
            {:error, {:property_not_writable, key}}

          true ->
            {:ok, object}
        end

      nil when not object.extensible ->
        {:error, {:object_not_extensible, key}}

      _current ->
        if object.kind == :array and is_integer(key) and key >= object.length and
             not object.length_writable,
           do: {:error, {:property_not_writable, "length"}},
           else: {:ok, object}
    end
  end

  defp store_descriptor(execution, id, object, key, property) do
    with {:ok, object} <- validate_definition(object, key, property) do
      execution = maybe_charge_property(execution, object, key, property.value)
      object = put_property_struct(object, key, property)
      {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
    end
  end

  defp accessor?(%Property{kind: :accessor}), do: true
  defp accessor?(_property), do: false

  defp property(value, opts) do
    %Property{
      value: value,
      writable: Keyword.get(opts, :writable, true),
      enumerable: Keyword.get(opts, :enumerable, true),
      configurable: Keyword.get(opts, :configurable, true)
    }
  end

  defp put_property(object, key, value) do
    case Map.get(object.properties, key) do
      {_old_value} -> put_default_property(object, key, value)
      %Property{} = property -> put_property_struct(object, key, %{property | value: value})
      nil -> put_default_property(object, key, value)
    end
  end

  defp put_property_struct(%Object{} = object, key, property) do
    if default_data_property?(property) do
      put_default_property(object, key, property.value)
    else
      object = remember_property(object, key)
      %{object | properties: Map.put(object.properties, key, property)}
    end
  end

  defp put_default_property(object, key, value) do
    object = remember_property(object, key)
    object = %{object | properties: Map.put(object.properties, key, {value})}

    if object.kind == :array and is_integer(key) and key >= 0,
      do: %{object | length: max(object.length, key + 1)},
      else: object
  end

  defp remember_property(object, key) when is_integer(key), do: object

  defp remember_property(object, key) do
    if Map.has_key?(object.properties, key),
      do: object,
      else: %{object | property_order: object.property_order ++ [key]}
  end

  defp inherited_property(_execution, nil, _key, _depth), do: nil

  defp inherited_property(_execution, _prototype, _key, depth)
       when depth > @max_prototype_depth,
       do: %Property{writable: false}

  defp inherited_property(execution, %Reference{} = prototype, key, depth) do
    case fetch_object(execution, prototype) do
      {:ok, object} ->
        own_property_value(object, key) ||
          inherited_property(execution, object.prototype, key, depth + 1)

      :error ->
        nil
    end
  end

  defp default_data_property?(%Property{
         kind: :data,
         writable: true,
         enumerable: true,
         configurable: true,
         getter: nil,
         setter: nil
       }),
       do: true

  defp default_data_property?(_property), do: false

  defp own_property_value(object, key), do: Map.get(object.properties, key)

  defp property_enumerable?({_value}), do: true
  defp property_enumerable?(%Property{enumerable: enumerable}), do: enumerable

  defp current_accessor(%Property{} = property, field), do: Map.fetch!(property, field)
  defp current_accessor({_value}, _field), do: nil
  defp current_accessor(nil, _field), do: nil

  defp current_flag(%Property{} = property, field, _default), do: Map.fetch!(property, field)
  defp current_flag({_value}, _field, _default), do: true
  defp current_flag(nil, _field, default), do: default

  defp array_length_writable(%Object{length_writable: true}), do: :ok
  defp array_length_writable(_object), do: {:error, {:property_not_writable, "length"}}

  defp array_length(value)
       when is_integer(value) and value >= 0 and value <= 4_294_967_295,
       do: {:ok, value}

  defp array_length(value)
       when is_float(value) and value >= 0 and value <= 4_294_967_295 and trunc(value) == value,
       do: {:ok, trunc(value)}

  defp array_length(_value), do: {:error, :invalid_array_length}

  defp resize_array(object, length) when length >= object.length,
    do: {:ok, %{object | length: length}}

  defp resize_array(object, length) do
    removed =
      object.properties
      |> Map.keys()
      |> Enum.filter(&(is_integer(&1) and &1 >= length))

    if Enum.any?(removed, &match?(%Property{configurable: false}, object.properties[&1])) do
      {:error, :nonconfigurable_array_element}
    else
      {:ok,
       %{
         object
         | length: length,
           properties: Map.drop(object.properties, removed),
           property_order: object.property_order -- removed
       }}
    end
  end

  defp normalize_key(key) when is_integer(key) and key in 0..4_294_967_294, do: key
  defp normalize_key(key) when is_integer(key), do: Integer.to_string(key)

  defp normalize_key(key)
       when is_float(key) and key >= 0 and key <= 4_294_967_294 and trunc(key) == key,
       do: trunc(key)

  defp normalize_key(key) when is_float(key) and trunc(key) == key,
    do: Integer.to_string(trunc(key))

  defp normalize_key(<<first, _rest::binary>> = key) when first in ?0..?9 do
    case Integer.parse(key) do
      {index, ""} when index in 0..4_294_967_294 ->
        if Integer.to_string(index) == key, do: index, else: key

      _ ->
        key
    end
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: key
end
