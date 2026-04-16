defmodule QuickBEAM.BeamVM.Interpreter.Frame do
  @type t :: %__MODULE__{
    pc: non_neg_integer(),
    locals: tuple(),
    constants: [term()],
    var_refs: tuple(),
    stack_size: non_neg_integer(),
    instructions: tuple(),
    local_to_vref: %{non_neg_integer() => non_neg_integer()}
  }

  @enforce_keys [:pc, :locals, :constants, :var_refs, :stack_size, :instructions]
  defstruct [:pc, :locals, :constants, :var_refs, :stack_size, :instructions, local_to_vref: %{}]
end
