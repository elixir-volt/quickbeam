defmodule QuickBEAM.VM.Execution do
  @moduledoc false

  @enforce_keys [:atoms, :max_stack_depth, :remaining_steps, :step_limit]
  defstruct [
    :atoms,
    :current_function,
    :step_limit,
    globals: %{},
    depth: 0,
    max_stack_depth: 1_000,
    remaining_steps: 0
  ]

  @type t :: %__MODULE__{
          atoms: tuple(),
          current_function: QuickBEAM.VM.Function.t() | nil,
          globals: map(),
          depth: non_neg_integer(),
          max_stack_depth: pos_integer(),
          remaining_steps: non_neg_integer(),
          step_limit: pos_integer()
        }
end
