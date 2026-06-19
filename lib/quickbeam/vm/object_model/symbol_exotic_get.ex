defmodule QuickBEAM.VM.ObjectModel.SymbolExoticGet do
  @moduledoc "Symbol exotic own-property lookup helpers."

  def own_property({:symbol, desc}, key), do: own_symbol_property(desc, {:symbol, desc}, key)
  def own_property({:symbol, desc, _} = symbol, key), do: own_symbol_property(desc, symbol, key)

  defp own_symbol_property(desc, _symbol, "toString"),
    do: {:builtin, "toString", fn _, _ -> symbol_to_string(desc) end}

  defp own_symbol_property(_desc, symbol, "valueOf"),
    do: {:builtin, "valueOf", fn _, _ -> symbol end}

  defp own_symbol_property(:undefined, _symbol, "description"), do: :undefined
  defp own_symbol_property(desc, _symbol, "description"), do: desc
  defp own_symbol_property(_desc, _symbol, _key), do: :undefined

  defp symbol_to_string(:undefined), do: "Symbol()"
  defp symbol_to_string(desc), do: "Symbol(#{desc})"
end
