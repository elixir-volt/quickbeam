defmodule QuickBEAM.VM.Execution do
  @moduledoc """
  Defines all mutable state owned by one isolated VM evaluation.

  Programs are immutable and shareable; execution heaps, globals, frames,
  Promises, jobs, handlers, and resource counters are process-local.
  """

  @enforce_keys [:atoms, :max_stack_depth, :remaining_steps, :step_limit]
  defstruct [
    :atoms,
    :step_limit,
    callers: [],
    cells: %{},
    depth: 1,
    default_prototypes: %{},
    error_prototypes: %{},
    globals: %{},
    handlers: %{},
    heap: %{},
    jobs: {[], []},
    sync_jobs: {[], []},
    max_stack_depth: 1_000,
    memory_exceeded: false,
    memory_limit: :infinity,
    memory_used: 0,
    next_cell_id: 0,
    next_object_id: 0,
    next_promise_id: 0,
    operations: %{},
    promise_waiters: %{},
    promise_aggregates: %{},
    promises: %{},
    remaining_steps: 0
  ]

  @type t :: %__MODULE__{
          atoms: tuple(),
          callers: [
            QuickBEAM.VM.Frame.t()
            | QuickBEAM.VM.NativeFrame.t()
            | QuickBEAM.VM.ObjectAssignBoundary.t()
            | QuickBEAM.VM.AccessorBoundary.t()
            | QuickBEAM.VM.AsyncBoundary.t()
            | QuickBEAM.VM.ReactionBoundary.t()
            | QuickBEAM.VM.ConstructorBoundary.t()
            | QuickBEAM.VM.PromiseExecutorBoundary.t()
            | QuickBEAM.VM.ThenableBoundary.t()
            | QuickBEAM.VM.ThenGetterBoundary.t()
          ],
          cells: %{optional(non_neg_integer()) => term()},
          depth: non_neg_integer(),
          default_prototypes: %{
            optional(QuickBEAM.VM.Object.kind()) => QuickBEAM.VM.Reference.t()
          },
          error_prototypes: %{optional(String.t()) => QuickBEAM.VM.Reference.t()},
          globals: map(),
          handlers: %{optional(String.t()) => function()},
          heap: %{optional(non_neg_integer()) => QuickBEAM.VM.Object.t()},
          jobs: :queue.queue(term()),
          sync_jobs: :queue.queue(term()),
          max_stack_depth: pos_integer(),
          memory_exceeded: boolean(),
          memory_limit: pos_integer() | :infinity,
          memory_used: non_neg_integer(),
          next_cell_id: non_neg_integer(),
          next_object_id: non_neg_integer(),
          next_promise_id: non_neg_integer(),
          operations: %{
            optional(reference()) => {QuickBEAM.VM.PromiseReference.t(), pid()}
          },
          promise_waiters: %{optional(non_neg_integer()) => [term()]},
          promise_aggregates: %{optional(reference()) => map()},
          promises: %{
            optional(non_neg_integer()) => QuickBEAM.VM.Promise.state() | :resolving
          },
          remaining_steps: non_neg_integer(),
          step_limit: pos_integer()
        }
end
