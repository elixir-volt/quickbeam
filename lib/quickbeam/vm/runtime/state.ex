defmodule QuickBEAM.VM.Runtime.State do
  @moduledoc """
  Defines all mutable state owned by one isolated VM evaluation.

  Programs are immutable and shareable; execution heaps, globals, frames,
  Promises, jobs, handlers, and resource counters are process-local.
  """

  @empty_queue :queue.new()

  @enforce_keys [:atoms, :max_stack_depth, :remaining_steps, :step_limit]
  defstruct [
    :atoms,
    :step_limit,
    callers: [],
    cells: %{},
    compiler_context: nil,
    depth: 1,
    default_prototypes: %{},
    error_prototypes: %{},
    globals: %{},
    handlers: %{},
    heap: %{},
    jobs: @empty_queue,
    sync_jobs: @empty_queue,
    sync_jobs_pending?: false,
    max_stack_depth: 1_000,
    memory_exceeded: false,
    memory_limit: :infinity,
    memory_used: 0,
    measurement_target: nil,
    next_cell_id: 0,
    next_object_id: 0,
    next_promise_id: 0,
    next_symbol_id: 0,
    operations: %{},
    promise_waiters: %{},
    promise_aggregates: %{},
    promises: %{},
    remaining_steps: 0
  ]

  @type t :: %__MODULE__{
          atoms: tuple(),
          callers: [
            QuickBEAM.VM.Runtime.Frame.t()
            | QuickBEAM.VM.Runtime.Frame.Native.t()
            | QuickBEAM.VM.Runtime.Boundary.ObjectAssign.t()
            | QuickBEAM.VM.Runtime.Boundary.Accessor.t()
            | QuickBEAM.VM.Runtime.Boundary.Async.t()
            | QuickBEAM.VM.Runtime.Boundary.Reaction.t()
            | QuickBEAM.VM.Runtime.Boundary.Constructor.t()
            | QuickBEAM.VM.Runtime.Boundary.PromiseExecutor.t()
            | QuickBEAM.VM.Runtime.Boundary.Thenable.t()
            | QuickBEAM.VM.Runtime.Boundary.ThenGetter.t()
          ],
          cells: %{optional(non_neg_integer()) => term()},
          compiler_context:
            %{
              required(:deopt_module) => module(),
              required(:executor) => module(),
              required(:instrumentation) => module(),
              optional(atom()) => term()
            }
            | nil,
          depth: non_neg_integer(),
          default_prototypes: %{
            optional(QuickBEAM.VM.Runtime.Object.kind()) => QuickBEAM.VM.Runtime.Reference.t()
          },
          error_prototypes: %{optional(String.t()) => QuickBEAM.VM.Runtime.Reference.t()},
          globals: map(),
          handlers: %{optional(String.t()) => function()},
          heap: %{optional(non_neg_integer()) => QuickBEAM.VM.Runtime.Object.t()},
          jobs: :queue.queue(term()),
          sync_jobs: :queue.queue(term()),
          sync_jobs_pending?: boolean(),
          max_stack_depth: pos_integer(),
          memory_exceeded: boolean(),
          memory_limit: pos_integer() | :infinity,
          memory_used: non_neg_integer(),
          measurement_target: {pid(), reference()} | nil,
          next_cell_id: non_neg_integer(),
          next_object_id: non_neg_integer(),
          next_promise_id: non_neg_integer(),
          next_symbol_id: non_neg_integer(),
          operations: %{
            optional(reference()) => {QuickBEAM.VM.Runtime.Promise.Reference.t(), pid()}
          },
          promise_waiters: %{optional(non_neg_integer()) => [term()]},
          promise_aggregates: %{optional(reference()) => map()},
          promises: %{
            optional(non_neg_integer()) => QuickBEAM.VM.Runtime.Promise.state() | :resolving
          },
          remaining_steps: non_neg_integer(),
          step_limit: pos_integer()
        }

  @doc "Builds evaluation state with fresh owner-local job queues."
  @spec new(keyword()) :: t()
  def new(attributes) when is_list(attributes) do
    attributes =
      attributes
      |> Keyword.put_new(:jobs, :queue.new())
      |> Keyword.put_new(:sync_jobs, :queue.new())

    struct!(__MODULE__, attributes)
  end
end
