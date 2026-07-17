defmodule QuickBEAM.VM.Bytecode.Atom do
  @moduledoc "QuickJS predefined atoms generated from the vendored atom header."

  @table QuickBEAM.VM.ABI.predefined_atoms()

  @doc "Looks up a predefined atom by its QuickJS index."
  def lookup(index) when is_map_key(@table, index), do: Map.fetch!(@table, index)
  def lookup(_index), do: nil

  @doc "Returns the number of predefined QuickJS atoms."
  def count, do: map_size(@table)
end
