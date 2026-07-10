defmodule QuickBEAM.VM.Execution do
  @moduledoc false

  @enforce_keys [:atoms, :max_stack_depth, :remaining_steps, :step_limit]
  defstruct [
    :atoms,
    :step_limit,
    callers: [],
    cells: %{},
    depth: 1,
    globals: %{},
    max_stack_depth: 1_000,
    next_cell_id: 0,
    remaining_steps: 0
  ]

  @type t :: %__MODULE__{
          atoms: tuple(),
          callers: [QuickBEAM.VM.Frame.t()],
          cells: %{optional(non_neg_integer()) => term()},
          depth: pos_integer(),
          globals: map(),
          max_stack_depth: pos_integer(),
          next_cell_id: non_neg_integer(),
          remaining_steps: non_neg_integer(),
          step_limit: pos_integer()
        }
end
