defmodule QuickBEAM.VM.IteratorBoundary do
  @moduledoc "Defines resumable state while a Promise combinator consumes an iterator."

  @enforce_keys [:consumer, :iterable, :caller, :depth]
  defstruct [
    :consumer,
    :kind,
    :promise,
    :target,
    :iterable,
    :iterator,
    :next,
    :result,
    :phase,
    :caller,
    :depth,
    values: [],
    tail?: false
  ]

  @type phase ::
          :iterator_getter
          | :iterator_factory
          | :next_getter
          | :next_call
          | :done_getter
          | :value_getter

  @type t :: %__MODULE__{
          consumer: :promise | :set,
          kind: :all | :all_settled | :any | :race | nil,
          promise: QuickBEAM.VM.PromiseReference.t() | nil,
          target: QuickBEAM.VM.Reference.t() | nil,
          iterable: term(),
          iterator: term() | nil,
          next: term() | nil,
          result: term() | nil,
          phase: phase() | nil,
          caller: term(),
          depth: non_neg_integer(),
          values: [term()],
          tail?: boolean()
        }
end
