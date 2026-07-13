defmodule QuickBEAM.VM.Builtins.String do
  @moduledoc "Defines the declarative core `String` static and prototype methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Heap, Object, Properties, Reference, RegExp, Value}

  builtin "String", kind: :intrinsic do
    static :from_char_code, js: "fromCharCode", length: 1

    prototype do
      method :char_code_at, js: "charCodeAt", length: 1
      method :includes, length: 1
      method :replace, length: 2
      method :slice, length: 2
      method :split, length: 2
      method :starts_with, js: "startsWith", length: 1
      method :to_lower_case, js: "toLowerCase", length: 0
      method :to_string_method, js: "toString", length: 0
    end
  end

  @doc "Implements `String.fromCharCode`."
  def from_char_code(%Call{arguments: values, execution: execution}),
    do: {:ok, Value.string_from_char_codes(values), execution}

  @doc "Implements UTF-16 `String.prototype.charCodeAt`."
  def char_code_at(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      index = arguments |> List.first(0) |> Value.to_int32()
      {:ok, Value.string_char_code_at(value, index), execution}
    end)
  end

  @doc "Implements `String.prototype.includes`."
  def includes(%Call{} = call) do
    with_string(call, fn value, arguments, execution ->
      part = arguments |> List.first(:undefined) |> Value.to_string_value()
      {:ok, String.contains?(value, part), execution}
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

  @doc "Implements `String.prototype.toLowerCase`."
  def to_lower_case(%Call{} = call),
    do:
      with_string(call, fn value, _arguments, execution ->
        {:ok, String.downcase(value), execution}
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
