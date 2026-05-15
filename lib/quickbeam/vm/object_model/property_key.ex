defmodule QuickBEAM.VM.ObjectModel.PropertyKey do
  @moduledoc "Property key normalization and classification for JS object model."

  import QuickBEAM.VM.Value, only: [is_symbol: 1]

  @doc "Normalize a JS value to a property key (string or symbol)."
  def normalize(k) when is_binary(k), do: k
  def normalize({:symbol, "Symbol." <> _ = name, _ref}), do: {:symbol, name}
  def normalize(k) when is_symbol(k), do: k
  def normalize(k) when is_integer(k) and k >= 0, do: Integer.to_string(k)
  def normalize(k) when is_float(k), do: QuickBEAM.VM.Interpreter.Values.stringify(k)
  def normalize({:tagged_int, n}), do: Integer.to_string(n)
  def normalize(k), do: QuickBEAM.VM.Interpreter.Values.stringify(k)

  @doc "Check if a key is a symbol."
  defguard is_symbol_key(k) when is_symbol(k)

  @doc "Try to parse a key as an array index."
  def array_index(k) when is_integer(k) and k >= 0 and k <= 4_294_967_294, do: {:ok, k}
  def array_index(k) when is_integer(k) and k >= 0, do: :error

  def array_index(k) when is_float(k) and k >= 0 and k <= 4_294_967_294 and k == trunc(k),
    do: {:ok, trunc(k)}

  def array_index(k) when is_float(k) and k >= 0, do: :error

  def array_index(k) when is_binary(k) do
    case Integer.parse(k) do
      {idx, ""} when idx >= 0 and idx <= 4_294_967_294 ->
        if Integer.to_string(idx) == k, do: {:ok, idx}, else: :error

      _ ->
        :error
    end
  end

  def array_index(_), do: :error
end
