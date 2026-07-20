defmodule QuickBEAM.VM.Runtime.Boundary.ObjectAssign do
  @moduledoc """
  Tracks resumable `Object.assign` property reads and writes.

  Source getters and target setters may execute arbitrary JavaScript, so the
  operation stores its remaining sources and keys in explicit machine state.
  """

  @enforce_keys [:target, :sources, :caller, :depth]
  defstruct [
    :target,
    :sources,
    :source,
    :caller,
    :depth,
    :phase,
    :key,
    keys: [],
    tail?: false
  ]

  @type t :: %__MODULE__{
          target: QuickBEAM.VM.Runtime.Reference.t(),
          sources: [term()],
          source: term() | nil,
          caller: QuickBEAM.VM.Runtime.Frame.t() | QuickBEAM.VM.Runtime.Frame.Native.t(),
          depth: non_neg_integer(),
          phase: :get | :set | nil,
          key: term() | nil,
          keys: [term()],
          tail?: boolean()
        }
end
