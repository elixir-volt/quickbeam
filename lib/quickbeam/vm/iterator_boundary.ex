defmodule QuickBEAM.VM.IteratorBoundary do
  @moduledoc "Defines resumable state while a Promise combinator consumes an iterator."

  @enforce_keys [:kind, :promise, :iterable, :caller, :depth]
  defstruct [
    :kind,
    :promise,
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
          kind: :all | :all_settled | :any | :race,
          promise: QuickBEAM.VM.PromiseReference.t(),
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
