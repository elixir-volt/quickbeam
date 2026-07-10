defmodule QuickBEAM.VM.Reaction do
  @moduledoc """
  Defines a queued Promise reaction and the Promise produced by that reaction.
  """

  @enforce_keys [:result_promise]
  defstruct [:result_promise, kind: :then, on_fulfilled: :undefined, on_rejected: :undefined]

  @type t :: %__MODULE__{
          result_promise: QuickBEAM.VM.PromiseReference.t(),
          kind: :then | :finally,
          on_fulfilled: term(),
          on_rejected: term()
        }
end
