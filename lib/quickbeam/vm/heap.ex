defmodule QuickBEAM.VM.Heap do
  @moduledoc false

  alias QuickBEAM.VM.{Execution, Object, Property, Reference}

  @max_prototype_depth 1_000

  @spec allocate(Execution.t(), Object.kind(), keyword()) :: {Reference.t(), Execution.t()}
  def allocate(%Execution{} = execution, kind \\ :ordinary, opts \\ []) do
    id = execution.next_object_id

    object = %Object{
      kind: kind,
      prototype: Keyword.get(opts, :prototype),
      length: Keyword.get(opts, :length, 0),
      callable: Keyword.get(opts, :callable),
      internal: Keyword.get(opts, :internal)
    }

    reference = %Reference{id: id}
    execution = %{execution | heap: Map.put(execution.heap, id, object), next_object_id: id + 1}
    {reference, execution}
  end

  @spec fetch_object(Execution.t(), Reference.t()) :: {:ok, Object.t()} | :error
  def fetch_object(%Execution{} = execution, %Reference{id: id}),
    do: Map.fetch(execution.heap, id)

  @spec get(Execution.t(), Reference.t(), term()) :: {:ok, term()} | {:error, term()}
  def get(%Execution{} = execution, %Reference{} = reference, key) do
    get_with_depth(execution, reference, normalize_key(key), 0)
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

    with {:ok, object} <- fetch_object(execution, reference),
         :ok <- writable?(object, key) do
      object = put_property(object, key, value)
      {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
    else
      :error -> {:error, {:invalid_reference, id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec define(Execution.t(), Reference.t(), term(), term(), keyword()) ::
          {:ok, Execution.t()} | {:error, term()}
  def define(%Execution{} = execution, %Reference{id: id} = reference, key, value, opts \\ []) do
    key = normalize_key(key)

    with {:ok, object} <- fetch_object(execution, reference) do
      property = %Property{
        value: value,
        writable: Keyword.get(opts, :writable, true),
        enumerable: Keyword.get(opts, :enumerable, true),
        configurable: Keyword.get(opts, :configurable, true)
      }

      object = put_property_struct(object, key, property)
      {:ok, %{execution | heap: Map.put(execution.heap, id, object)}}
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
            object = %{object | properties: Map.delete(object.properties, key)}
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

  @spec own_keys(Execution.t(), Reference.t()) :: {:ok, [term()]} | {:error, term()}
  def own_keys(execution, %Reference{id: id} = reference) do
    case fetch_object(execution, reference) do
      {:ok, object} ->
        keys = for {key, property} <- object.properties, property.enumerable, do: key
        {:ok, keys}

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  defp get_with_depth(_execution, _reference, _key, depth) when depth > @max_prototype_depth,
    do: {:error, :prototype_chain_too_deep}

  defp get_with_depth(execution, %Reference{id: id} = reference, key, depth) do
    case fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length}} when key == "length" ->
        {:ok, length}

      {:ok, object} ->
        case Map.fetch(object.properties, key) do
          {:ok, %Property{value: value}} ->
            {:ok, value}

          :error when is_struct(object.prototype, Reference) ->
            get_with_depth(execution, object.prototype, key, depth + 1)

          :error ->
            {:ok, :undefined}
        end

      :error ->
        {:error, {:invalid_reference, id}}
    end
  end

  defp writable?(%Object{properties: properties, extensible: extensible}, key) do
    case Map.fetch(properties, key) do
      {:ok, %Property{writable: true}} -> :ok
      {:ok, %Property{writable: false}} -> {:error, {:property_not_writable, key}}
      :error when extensible -> :ok
      :error -> {:error, {:object_not_extensible, key}}
    end
  end

  defp put_property(object, key, value) do
    property =
      case Map.get(object.properties, key) do
        %Property{} = property -> %{property | value: value}
        nil -> %Property{value: value}
      end

    put_property_struct(object, key, property)
  end

  defp put_property_struct(%Object{kind: :array} = object, key, property)
       when is_integer(key) and key >= 0 do
    %{
      object
      | properties: Map.put(object.properties, key, property),
        length: max(object.length, key + 1)
    }
  end

  defp put_property_struct(object, key, property),
    do: %{object | properties: Map.put(object.properties, key, property)}

  defp normalize_key(key) when is_integer(key) and key >= 0, do: key

  defp normalize_key(key) when is_float(key) and key >= 0 and trunc(key) == key,
    do: trunc(key)

  defp normalize_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {index, ""} when index >= 0 -> if Integer.to_string(index) == key, do: index, else: key
      _ -> key
    end
  end

  defp normalize_key(key), do: key
end
