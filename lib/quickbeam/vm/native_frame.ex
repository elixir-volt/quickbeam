defmodule QuickBEAM.VM.NativeFrame do
  @moduledoc "Defines resumable state for a VM-implemented native callback."

  @enforce_keys [:operation, :values, :callback, :receiver, :caller]
  defstruct [
    :operation,
    :values,
    :callback,
    :receiver,
    :caller,
    :accumulator,
    index: 0,
    results: [],
    tail?: false
  ]

  @type t :: %__MODULE__{
          operation: :map | :filter | :for_each | :some | :reduce,
          values: tuple(),
          callback: term(),
          receiver: term(),
          caller: QuickBEAM.VM.Frame.t(),
          accumulator: term(),
          index: non_neg_integer(),
          results: [term()],
          tail?: boolean()
        }
end
