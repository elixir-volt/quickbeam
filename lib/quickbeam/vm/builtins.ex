defmodule QuickBEAM.VM.Builtins do
  @moduledoc false

  alias QuickBEAM.VM.{Execution, Heap, Object, Property, Reference, RegExp, Value}

  @constructors %{
    "Array" => ["isArray"],
    "Object" => ["assign", "create", "keys"],
    "Math" => ["floor", "max", "min", "random", "round"],
    "String" => ["fromCharCode"],
    "Error" => [],
    "Promise" => ["resolve"],
    "Set" => []
  }

  @spec install(Execution.t()) :: Execution.t()
  def install(execution) do
    Enum.reduce(@constructors, execution, fn {name, methods}, execution ->
      {object, execution} = Heap.allocate(execution, :ordinary, callable: {:builtin, name})

      execution =
        Enum.reduce(methods, execution, fn method, execution ->
          {:ok, execution} =
            Heap.define(execution, object, method, {:builtin_method, name, method},
              enumerable: false
            )

          execution
        end)

      execution = maybe_install_prototype(name, object, execution)
      %{execution | globals: Map.put_new(execution.globals, name, object)}
    end)
  end

  @spec callable(Execution.t(), Reference.t()) :: term() | nil
  def callable(execution, %Reference{} = reference) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{callable: callable}} -> callable
      :error -> nil
    end
  end

  @spec call(term(), term(), [term()], Execution.t()) ::
          {:ok, term(), Execution.t()} | {:error, term(), Execution.t()}
  def call({:builtin_method, "Array", "isArray"}, _this, [value], execution),
    do: {:ok, array?(value, execution), execution}

  def call({:builtin_method, "Object", "keys"}, _this, [value], execution) do
    with {:ok, keys} <- own_keys(value, execution) do
      {array, execution} = array_from(keys, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:builtin_method, "Object", "create"}, _this, [prototype], execution) do
    prototype = if match?(%Reference{}, prototype), do: prototype, else: nil
    {object, execution} = Heap.allocate(execution, :ordinary, prototype: prototype)
    {:ok, object, execution}
  end

  def call({:builtin_method, "Object", "assign"}, _this, [target | sources], execution) do
    Enum.reduce_while(sources, {:ok, target, execution}, fn source, {:ok, target, execution} ->
      case assign(target, source, execution) do
        {:ok, execution} -> {:cont, {:ok, target, execution}}
        {:error, reason} -> {:halt, {:error, reason, execution}}
      end
    end)
  end

  def call({:builtin_method, "Math", "floor"}, _this, [value], execution),
    do: {:ok, value |> Value.to_number() |> floor_number(), execution}

  def call({:builtin_method, "Math", "round"}, _this, [value], execution),
    do: {:ok, value |> Value.to_number() |> round_number(), execution}

  def call({:builtin_method, "Math", "random"}, _this, [], execution),
    do: {:ok, 0.5, execution}

  def call({:builtin_method, "Math", "min"}, _this, values, execution),
    do: {:ok, numeric_extreme(values, &min/2, :infinity), execution}

  def call({:builtin_method, "Math", "max"}, _this, values, execution),
    do: {:ok, numeric_extreme(values, &max/2, :neg_infinity), execution}

  def call({:builtin_method, "String", "fromCharCode"}, _this, values, execution) do
    string = values |> Enum.map(&Value.to_int32/1) |> List.to_string()
    {:ok, string, execution}
  end

  def call({:builtin_method, "Promise", "resolve"}, _this, values, execution) do
    {promise, execution} = QuickBEAM.VM.Promise.new(execution)

    value =
      case values do
        [value | _] -> value
        [] -> :undefined
      end

    execution = QuickBEAM.VM.Promise.settle(execution, promise, {:ok, value})
    {:ok, promise, execution}
  end

  def call({:primitive_method, :number, "toString"}, value, arguments, execution) do
    radix =
      case arguments do
        [radix | _] -> Value.to_int32(radix)
        [] -> 10
      end

    {:ok, number_to_string(value, radix), execution}
  end

  def call({:primitive_method, :number, "toFixed"}, value, arguments, execution) do
    digits =
      case arguments do
        [digits | _] -> Value.to_int32(digits)
        [] -> 0
      end

    {:ok, :erlang.float_to_binary(value / 1, decimals: digits), execution}
  end

  def call({:primitive_method, :string, "toString"}, value, _arguments, execution),
    do: {:ok, value, execution}

  def call({:primitive_method, :string, "toLowerCase"}, value, _arguments, execution),
    do: {:ok, String.downcase(value), execution}

  def call({:primitive_method, :string, "startsWith"}, value, [prefix | _], execution),
    do: {:ok, String.starts_with?(value, Value.to_string_value(prefix)), execution}

  def call({:primitive_method, :string, "includes"}, value, [part | _], execution),
    do: {:ok, String.contains?(value, Value.to_string_value(part)), execution}

  def call({:primitive_method, :string, "charCodeAt"}, value, [index | _], execution) do
    result = value |> String.at(Value.to_int32(index)) |> char_code()
    {:ok, result, execution}
  end

  def call({:primitive_method, :string, "slice"}, value, arguments, execution) do
    {start, length} = slice_range(String.length(value), arguments)
    {:ok, String.slice(value, start, length), execution}
  end

  def call({:primitive_method, :string, "replace"}, value, [pattern, replacement | _], execution) do
    {:ok, replace_string(value, pattern, Value.to_string_value(replacement)), execution}
  end

  def call({:primitive_method, :string, "split"}, value, arguments, execution) do
    parts =
      case arguments do
        [] -> [value]
        [separator | _] -> String.split(value, Value.to_string_value(separator))
      end

    {array, execution} = array_from(parts, execution)
    {:ok, array, execution}
  end

  def call({:primitive_method, :regexp, "test"}, %RegExp{} = regexp, [value | _], execution),
    do: {:ok, regex_match?(regexp, Value.to_string_value(value)), execution}

  def call({:primitive_method, :array, "join"}, value, arguments, execution) do
    separator =
      case arguments do
        [separator | _] -> Value.to_string_value(separator)
        [] -> ","
      end

    with {:ok, values} <- array_values(value, execution) do
      {:ok, Enum.map_join(values, separator, &Value.to_string_value/1), execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :array, "slice"}, value, arguments, execution) do
    with {:ok, values} <- array_values(value, execution) do
      {start, length} = slice_range(length(values), arguments)
      {array, execution} = array_from(Enum.slice(values, start, length), execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:primitive_method, :array, "concat"}, value, arguments, execution) do
    with {:ok, values} <- array_values(value, execution) do
      values =
        Enum.reduce(arguments, values, fn item, values ->
          values ++ concat_values(item, execution)
        end)

      {array, execution} = array_from(values, execution)
      {:ok, array, execution}
    else
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:builtin, "String"}, _this, [value], execution),
    do: {:ok, Value.to_string_value(value), execution}

  def call({:builtin, "String"}, _this, [], execution), do: {:ok, "", execution}

  def call({:builtin, "Set"}, _this, values, execution) do
    entries =
      case values do
        [value | _] ->
          case array_values(value, execution) do
            {:ok, entries} -> entries
            _ -> []
          end

        [] ->
          []
      end

    {set, execution} = Heap.allocate(execution, :set, internal: MapSet.new(entries))
    {:ok, set, execution}
  end

  def call({:primitive_method, :set, "has"}, %Reference{} = set, [value | _], execution) do
    case Heap.fetch_object(execution, set) do
      {:ok, %Object{kind: :set, internal: entries}} ->
        {:ok, MapSet.member?(entries, value), execution}

      _ ->
        {:error, :not_a_set, execution}
    end
  end

  def call({:primitive_method, :set, "add"}, %Reference{} = set, [value | _], execution) do
    case Heap.update_object(execution, set, fn object ->
           %{object | internal: MapSet.put(object.internal, value)}
         end) do
      {:ok, execution} -> {:ok, set, execution}
      {:error, reason} -> {:error, reason, execution}
    end
  end

  def call({:builtin, "Array"}, _this, values, execution) do
    {array, execution} = array_from(values, execution)
    {:ok, array, execution}
  end

  def call({:builtin, "Object"}, _this, [value], execution) when value not in [nil, :undefined],
    do: {:ok, value, execution}

  def call({:builtin, "Object"}, _this, _values, execution) do
    {object, execution} = Heap.allocate(execution)
    {:ok, object, execution}
  end

  def call({:builtin, "Error"}, _this, values, execution),
    do:
      {:ok, %{name: "Error", message: Value.to_string_value(List.first(values) || "")}, execution}

  def call(callable, _this, _arguments, execution),
    do: {:error, {:unsupported_builtin, callable}, execution}

  defp maybe_install_prototype("Promise", constructor, execution) do
    {prototype, execution} = Heap.allocate(execution)

    {:ok, execution} =
      Heap.define(execution, prototype, "then", {:promise_method, "then"}, enumerable: false)

    {:ok, execution} =
      Heap.define(execution, constructor, "prototype", prototype, enumerable: false)

    execution
  end

  defp maybe_install_prototype(_name, _constructor, execution), do: execution

  defp array?(%Reference{} = reference, execution) do
    match?({:ok, %Object{kind: :array}}, Heap.fetch_object(execution, reference))
  end

  defp array?(value, _execution), do: is_list(value)

  defp array_from(values, execution) do
    {array, execution} = Heap.allocate(execution, :array)

    execution =
      values
      |> Enum.with_index()
      |> Enum.reduce(execution, fn {value, index}, execution ->
        {:ok, execution} = Heap.define(execution, array, index, value)
        execution
      end)

    {array, execution}
  end

  defp own_keys(%Reference{} = reference, execution), do: Heap.own_keys(execution, reference)
  defp own_keys(value, _execution) when is_map(value), do: {:ok, Map.keys(value)}
  defp own_keys([], _execution), do: {:ok, []}

  defp own_keys(value, _execution) when is_list(value),
    do: {:ok, Enum.to_list(0..(length(value) - 1))}

  defp own_keys(_value, _execution), do: {:ok, []}

  defp assign(%Reference{} = target, source, execution) do
    with {:ok, keys} <- own_keys(source, execution) do
      Enum.reduce_while(keys, {:ok, execution}, fn key, {:ok, execution} ->
        with {:ok, value} <- property(source, key, execution),
             {:ok, execution} <- Heap.put(execution, target, key, value) do
          {:cont, {:ok, execution}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp assign(_target, _source, _execution), do: {:error, :not_an_object}

  defp property(%Reference{} = reference, key, execution), do: Heap.get(execution, reference, key)

  defp property(value, key, _execution) when is_map(value),
    do: {:ok, Map.get(value, key, :undefined)}

  defp property(value, key, _execution) when is_list(value),
    do: {:ok, Enum.at(value, key, :undefined)}

  defp array_values(value, _execution) when is_list(value), do: {:ok, value}

  defp array_values(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{kind: :array, length: length, properties: properties}} ->
        values =
          if length == 0,
            do: [],
            else: for(index <- 0..(length - 1), do: property_value(properties, index))

        {:ok, values}

      _ ->
        {:error, :not_an_array}
    end
  end

  defp array_values(_value, _execution), do: {:error, :not_an_array}

  defp concat_values(value, execution) do
    case array_values(value, execution) do
      {:ok, values} -> values
      {:error, _} -> [value]
    end
  end

  defp property_value(properties, index) do
    case Map.get(properties, index) do
      %Property{value: value} -> value
      nil -> :undefined
    end
  end

  defp slice_range(size, arguments) do
    start =
      case arguments do
        [start | _] -> normalize_index(Value.to_int32(start), size)
        [] -> 0
      end

    finish =
      case arguments do
        [_start, finish | _] -> normalize_index(Value.to_int32(finish), size)
        _ -> size
      end

    {start, max(finish - start, 0)}
  end

  defp normalize_index(index, size) when index < 0, do: max(size + index, 0)
  defp normalize_index(index, size), do: min(index, size)

  defp number_to_string(value, 10), do: Value.to_string_value(value)

  defp number_to_string(value, radix) when is_integer(value) and radix in 2..36,
    do: Integer.to_string(value, radix)

  defp number_to_string(value, _radix), do: Value.to_string_value(value)

  defp char_code(nil), do: :nan
  defp char_code(character), do: character |> String.to_charlist() |> hd()

  defp regex_match?(%RegExp{source: source}, value) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _} -> false
    end
  end

  defp replace_string(value, %RegExp{source: source}, replacement) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.replace(regex, value, replacement)
      {:error, _} -> value
    end
  end

  defp replace_string(value, pattern, replacement),
    do: String.replace(value, Value.to_string_value(pattern), replacement, global: false)

  defp floor_number(value) when is_number(value), do: floor(value)
  defp floor_number(value), do: value
  defp round_number(value) when is_number(value), do: round(value)
  defp round_number(value), do: value

  defp numeric_extreme(values, operation, initial) do
    Enum.reduce(values, initial, fn value, result ->
      operation.(Value.to_number(value), result)
    end)
  end
end
