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
    handlers: %{},
    heap: %{},
    jobs: {[], []},
    max_stack_depth: 1_000,
    next_cell_id: 0,
    next_object_id: 0,
    next_promise_id: 0,
    operations: %{},
    promises: %{},
    remaining_steps: 0
  ]

  @type t :: %__MODULE__{
          atoms: tuple(),
          callers: [QuickBEAM.VM.Frame.t()],
          cells: %{optional(non_neg_integer()) => term()},
          depth: pos_integer(),
          globals: map(),
          handlers: %{optional(String.t()) => function()},
          heap: %{optional(non_neg_integer()) => QuickBEAM.VM.Object.t()},
          jobs: :queue.queue({:ok, term()} | {:error, term()}),
          max_stack_depth: pos_integer(),
          next_cell_id: non_neg_integer(),
          next_object_id: non_neg_integer(),
          next_promise_id: non_neg_integer(),
          operations: %{
            optional(reference()) => {QuickBEAM.VM.PromiseReference.t(), pid()}
          },
          promises: %{optional(non_neg_integer()) => QuickBEAM.VM.Promise.state()},
          remaining_steps: non_neg_integer(),
          step_limit: pos_integer()
        }
end
