defmodule QuickBEAM.VM.Compiler.Lowering.Atoms do
  @moduledoc "Shared atom/local-name resolution helpers for compiler lowering."

  alias QuickBEAM.VM.PredefinedAtoms

  @doc "Resolves QuickJS atom operands and local names into their string names."
  def resolve(name, _atoms) when is_binary(name), do: name
  def resolve({:tagged_int, value}, _atoms), do: value
  def resolve({:predefined, idx}, _atoms), do: PredefinedAtoms.lookup(idx)

  def resolve(idx, atoms)
      when is_integer(idx) and is_tuple(atoms) and idx >= 0 and idx < tuple_size(atoms),
      do: elem(atoms, idx)

  def resolve(_name, _atoms), do: nil
end
