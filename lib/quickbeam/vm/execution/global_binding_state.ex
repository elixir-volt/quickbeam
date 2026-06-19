defmodule QuickBEAM.VM.Execution.GlobalBindingState do
  @moduledoc "Process-local flags for global lexical and const bindings."

  def mark_const(name, true), do: Process.put({:qb_const_global, name}, true)
  def mark_const(name, false), do: Process.delete({:qb_const_global, name})

  def const?(name), do: Process.get({:qb_const_global, name}) == true

  def mark_lexical(name, true), do: Process.put({:qb_lexical_global, name}, true)
  def mark_lexical(name, false), do: Process.delete({:qb_lexical_global, name})

  def lexical?(name), do: Process.get({:qb_lexical_global, name}) == true
end
