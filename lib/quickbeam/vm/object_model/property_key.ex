defmodule QuickBEAM.VM.ObjectModel.PropertyKey do
  @moduledoc "Property key normalization and classification for JS object model."

  import QuickBEAM.VM.Value, only: [is_symbol: 1]

  @doc "Normalize a JS value to a property key (string or symbol)."
  def normalize(k) when is_binary(k), do: k
  def normalize(k) when is_symbol(k), do: k
  def normalize(k) when is_integer(k) and k >= 0, do: Integer.to_string(k)
  def normalize(k) when is_float(k) and k == trunc(k) and k >= 0, do: Integer.to_string(trunc(k))
  def normalize(k) when is_float(k), do: QuickBEAM.VM.Interpreter.Values.stringify(k)
  def normalize({:tagged_int, n}), do: Integer.to_string(n)
  def normalize(k), do: k

  @doc "Check if a key is a symbol."
  defguard is_symbol_key(k) when is_symbol(k)

  @doc "Try to parse a key as an array index."
  def array_index(k) when is_integer(k) and k >= 0, do: {:ok, k}

  def array_index(k) when is_binary(k) do
    case Integer.parse(k) do
      {idx, ""} when idx >= 0 -> {:ok, idx}
      _ -> :error
    end
  end

  def array_index(_), do: :error
end
