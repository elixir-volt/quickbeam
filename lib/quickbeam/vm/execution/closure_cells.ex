defmodule QuickBEAM.VM.Execution.ClosureCells do
  @moduledoc "Boundary for reading and writing interpreter closure cells from runtime semantics."

  alias QuickBEAM.VM.Interpreter.Closures

  def read(cell), do: Closures.read_cell(cell)
  def write(cell, value), do: Closures.write_cell(cell, value)
end
