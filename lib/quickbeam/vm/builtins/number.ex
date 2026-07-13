defmodule QuickBEAM.VM.Builtins.Number do
  @moduledoc "Defines declarative `Number` prototype methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.{Heap, Object, Reference, Value}

  builtin "Number", kind: :extension do
    prototype do
      method("toFixed", :to_fixed, length: 1)
      method("toString", :to_string_method, length: 1)
    end
  end

  @doc "Implements `Number.prototype.toFixed`."
  def to_fixed(%Call{} = call) do
    with_number(call, fn value, arguments, execution ->
      digits = arguments |> List.first(0) |> Value.to_int32()

      result =
        if is_number(value) and digits in 0..100,
          do: :erlang.float_to_binary(value / 1, decimals: digits),
          else: Value.to_string_value(value)

      {:ok, result, execution}
    end)
  end

  @doc "Implements `Number.prototype.toString`."
  def to_string_method(%Call{} = call) do
    with_number(call, fn value, arguments, execution ->
      radix =
        case arguments do
          [] -> 10
          [:undefined | _] -> 10
          [radix | _] -> Value.to_int32(radix)
        end

      {:ok, number_to_string(value, radix), execution}
    end)
  end

  defp with_number(%Call{this: receiver, arguments: arguments, execution: execution}, callback) do
    case number_value(receiver, execution) do
      {:ok, value} -> callback.(value, arguments, execution)
      :error -> {:error, :incompatible_number_receiver, execution}
    end
  end

  defp number_value(value, _execution)
       when is_number(value) or value in [:nan, :infinity, :neg_infinity],
       do: {:ok, value}

  defp number_value(%Reference{} = reference, execution) do
    case Heap.fetch_object(execution, reference) do
      {:ok, %Object{internal: {:primitive, :number, value}}} -> {:ok, value}
      _other -> :error
    end
  end

  defp number_value(_value, _execution), do: :error

  defp number_to_string(value, 10), do: Value.to_string_value(value)

  defp number_to_string(value, radix) when is_integer(value) and radix in 2..36,
    do: value |> Integer.to_string(radix) |> String.downcase()

  defp number_to_string(value, _radix), do: Value.to_string_value(value)
end
