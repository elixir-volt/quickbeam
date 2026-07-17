defmodule QuickBEAM.VM.Builtin.Number do
  @moduledoc "Defines declarative `Number` prototype methods."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Boundary
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Object
  alias QuickBEAM.VM.Runtime.Reference
  alias QuickBEAM.VM.Runtime.Value

  builtin "Number",
    kind: :constructor,
    constructor: :construct,
    length: 1,
    depends_on: ["Object", "Function"] do
    constant "MAX_VALUE", 1.7976931348623157e308
    constant "MIN_VALUE", 5.0e-324
    constant "POSITIVE_INFINITY", :infinity
    constant "NEGATIVE_INFINITY", :neg_infinity

    prototype extends: "Object", primitive: {:number, 0} do
      method :to_fixed, js: "toFixed", length: 1
      method :to_string_method, js: "toString", length: 1
    end
  end

  @doc "Implements Number call and boxed-construction semantics."
  def construct(%Call{
        this: %Reference{} = receiver,
        caller: %Boundary.Constructor{},
        arguments: arguments,
        execution: execution
      }) do
    value = arguments |> List.first(0) |> Value.to_number()

    {:ok, execution} =
      Heap.update_object(execution, receiver, fn object ->
        %{object | internal: {:primitive, :number, value}}
      end)

    {:ok, receiver, execution}
  end

  def construct(%Call{arguments: arguments, execution: execution}) do
    value = arguments |> List.first(0) |> Value.to_number()
    {:ok, value, execution}
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
