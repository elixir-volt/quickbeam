defmodule QuickBEAM.VM.Builtin.Math do
  @moduledoc "Defines the declarative core `Math` builtin object."

  use QuickBEAM.VM.Builtin

  alias QuickBEAM.VM.Builtin.Call
  alias QuickBEAM.VM.Runtime.Value

  builtin "Math", kind: :namespace, depends_on: ["Object", "Function"] do
    constant "E", :math.exp(1)
    constant "PI", :math.pi()

    static :floor_value, js: "floor", length: 1
    static :max_value, js: "max", length: 2
    static :min_value, js: "min", length: 2
    static :pow_value, js: "pow", length: 2
    static :random_value, js: "random", length: 0
    static :round_value, js: "round", length: 1
  end

  @doc "Implements `Math.floor`."
  def floor_value(%Call{arguments: arguments, execution: execution}) do
    value = arguments |> List.first(:undefined) |> Value.to_number()
    value = if is_number(value), do: floor(value), else: value
    {:ok, value, execution}
  end

  @doc "Implements `Math.round`."
  def round_value(%Call{arguments: arguments, execution: execution}) do
    value = arguments |> List.first(:undefined) |> Value.to_number()
    value = if is_number(value), do: round(value), else: value
    {:ok, value, execution}
  end

  @doc "Implements deterministic `Math.random` for the current VM profile."
  def random_value(%Call{execution: execution}), do: {:ok, 0.5, execution}

  @doc "Implements `Math.min`."
  def min_value(%Call{arguments: values, execution: execution}),
    do: {:ok, numeric_extreme(values, :min), execution}

  @doc "Implements `Math.max`."
  def max_value(%Call{arguments: values, execution: execution}),
    do: {:ok, numeric_extreme(values, :max), execution}

  @doc "Implements `Math.pow`."
  def pow_value(%Call{arguments: arguments, execution: execution}) do
    base = Enum.at(arguments, 0, :undefined)
    exponent = Enum.at(arguments, 1, :undefined)
    {:ok, Value.power(base, exponent), execution}
  end

  defp numeric_extreme(values, kind) do
    initial = if kind == :min, do: :infinity, else: :neg_infinity

    Enum.reduce_while(values, initial, fn value, result ->
      case Value.to_number(value) do
        :nan -> {:halt, :nan}
        number -> {:cont, extreme(kind, result, number)}
      end
    end)
  end

  defp extreme(:min, :infinity, number), do: number
  defp extreme(:min, :neg_infinity, _number), do: :neg_infinity
  defp extreme(:min, _result, :neg_infinity), do: :neg_infinity
  defp extreme(:min, result, :infinity), do: result
  defp extreme(:min, result, number), do: min(result, number)

  defp extreme(:max, :neg_infinity, number), do: number
  defp extreme(:max, :infinity, _number), do: :infinity
  defp extreme(:max, _result, :infinity), do: :infinity
  defp extreme(:max, result, :neg_infinity), do: result
  defp extreme(:max, result, number), do: max(result, number)
end
