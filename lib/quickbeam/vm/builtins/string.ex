defmodule QuickBEAM.VM.Builtins.String do
  @moduledoc "Defines the declarative core `String` static and prototype methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{ConstructorBoundary, Heap, Object, Properties, Reference, RegExp, Value}

  builtin "String",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function"] do
    static :from_char_code, js: "fromCharCode", length: 1

    prototype extends: "Object", primitive: {:string, ""} do
      method :char_at, js: "charAt", length: 1
      method :char_code_at, js: "charCodeAt", length: 1
      method :concat, length: 1
      method :ends_with, js: "endsWith", length: 1
      method :includes, length: 1
      method :index_of, js: "indexOf", length: 1
      method :replace, length: 2
      method :slice, length: 2
      method :split, length: 2
      method :starts_with, js: "startsWith", length: 1
      method :substring, length: 2
      method :to_lower_case, js: "toLowerCase", length: 0
      method :to_string_method, js: "toString", length: 0
      method :trim, length: 0
    end
  end

  @doc "Implements String call and boxed-construction semantics."
  def construct(%Call{
        this: %Reference{} = receiver,
        caller: %ConstructorBoundary{},
        arguments: arguments,
        execution: execution
      }) do
    value = arguments |> List.first("") |> Value.to_string_value()

    {:ok, execution} =
      Heap.update_object(execution, receiver, fn object ->
        %{object | internal: {:primitive, :string, value}}
      end)

    {:ok, receiver, execution}
  end

  def construct(%Call{arguments: arguments, execution: execution}) do
    value = arguments |> List.first("") |> Value.to_string_value()
    {:ok, value, execution}
  end

  @doc "Implements `String.fromCharCode`."
  def from_char_code(%Call{arguments: values, execution: execution}),
    do: {:ok, Value.string_from_char_codes(values), execution}

  @doc "Implements UTF-16 `String.prototype.charAt`."
  def char_at(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      index = arguments |> List.first(0) |> Value.to_int32()

      result =
        case Value.string_at(value, index) do
          :undefined -> ""
          character -> character
        end

      {:ok, result, execution}
    end)
  end

  @doc "Implements UTF-16 `String.prototype.charCodeAt`."
  def char_code_at(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      index = arguments |> List.first(0) |> Value.to_int32()
      {:ok, Value.string_char_code_at(value, index), execution}
    end)
  end

  @doc "Implements `String.prototype.concat`."
  def concat(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      suffix = Enum.map_join(arguments, &Value.to_string_value/1)
      {:ok, value <> suffix, execution}
    end)
  end

  @doc "Implements `String.prototype.endsWith`."
  def ends_with(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      suffix = arguments |> List.first(:undefined) |> Value.to_string_value()
      {:ok, String.ends_with?(value, suffix), execution}
    end)
  end

  @doc "Implements `String.prototype.includes`."
  def includes(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      part = arguments |> List.first(:undefined) |> Value.to_string_value()
      {:ok, String.contains?(value, part), execution}
    end)
  end

  @doc "Implements `String.prototype.indexOf`."
  def index_of(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      searched = arguments |> List.first(:undefined) |> Value.to_string_value()

      index =
        case :binary.match(value, searched) do
          {index, _length} -> index
          :nomatch -> -1
        end

      {:ok, index, execution}
    end)
  end

  @doc "Implements `String.prototype.replace` for string and RegExp patterns."
  def replace(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      pattern = Enum.at(arguments, 0, :undefined)
      replacement = arguments |> Enum.at(1, :undefined) |> Value.to_string_value()
      {:ok, replace_string(value, pattern, replacement), execution}
    end)
  end

  @doc "Implements UTF-16 `String.prototype.slice`."
  def slice(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      {start, length} = slice_range(Value.string_length(value), arguments)
      {:ok, Value.string_slice(value, start, length), execution}
    end)
  end

  @doc "Implements `String.prototype.split`."
  def split(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      parts =
        case arguments do
          [] -> [value]
          [:undefined | _] -> [value]
          [separator | _] -> String.split(value, Value.to_string_value(separator))
        end

      {array, execution} = array_from(parts, execution)
      {:ok, array, execution}
    end)
  end

  @doc "Implements `String.prototype.startsWith`."
  def starts_with(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      prefix = arguments |> List.first(:undefined) |> Value.to_string_value()
      {:ok, String.starts_with?(value, prefix), execution}
    end)
  end

  @doc "Implements UTF-16 `String.prototype.substring`."
  def substring(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      size = Value.string_length(value)
      start = arguments |> Enum.at(0, 0) |> substring_index(size)
      finish = arguments |> Enum.at(1, size) |> substring_index(size)
      {start, finish} = if start <= finish, do: {start, finish}, else: {finish, start}
      {:ok, Value.string_slice(value, start, finish - start), execution}
    end)
  end

  @doc "Implements `String.prototype.toLowerCase`."
  def to_lower_case(%Call{} = call),
    do:
      with_string(call, fn value, _arguments, execution ->
        {:ok, String.downcase(value), execution}
      end)

  @doc "Implements `String.prototype.trim`."
  def trim(%Call{} = call),
    do:
      with_string(call, fn value, _arguments, execution ->
        {:ok, String.trim(value), execution}
      end)

  @doc "Implements `String.prototype.toString` with receiver validation."
  def to_string_method(%Call{} = call),
    do: with_string(call, fn value, _arguments, execution -> {:ok, value, execution} end)

  defp with_string(%Call{this: receiver, arguments: arguments, execution: execution}, callback) do
    case string_value(receiver, execution) do
      {:ok, value} -> callback.(value, arguments, execution)
      :error -> {:error, :incompatible_string_receiver, execution}
    end
  end

  defp string_value(value, _execution) when is_binary(value), do: {:ok, value}

  defp string_value(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{internal: {:primitive, :string, value}}} -> {:ok, value}
      _other -> :error
    end
  end

  defp string_value(_value, _execution), do: :error

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

  defp substring_index(value, size) do
    case Value.to_number(value) do
      :infinity -> size
      number when is_number(number) -> number |> trunc() |> max(0) |> min(size)
      _other -> 0
    end
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

  defp replace_string(value, %RegExp{source: source}, replacement) do
    case Regex.compile(source) do
      {:ok, regex} -> Regex.replace(regex, value, replacement)
      {:error, _reason} -> value
    end
  end

  defp replace_string(value, pattern, replacement),
    do: String.replace(value, Value.to_string_value(pattern), replacement, global: false)
end
