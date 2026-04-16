defmodule QuickBEAM.BeamVM.Interpreter.Frame do
  @enforce_keys [:pc, :locals, :constants, :var_refs, :stack_size, :instructions]
  defstruct [:pc, :locals, :constants, :var_refs, :stack_size, :instructions]
end
