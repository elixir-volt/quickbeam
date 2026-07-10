defmodule QuickBEAM.VM.AccessorBoundary do
  @moduledoc """
  Tracks completion of a JavaScript property accessor invocation.

  Getter completion pushes its value onto the saved caller frame. Setter
  completion ignores the accessor return value and resumes the caller unchanged.
  """

  @enforce_keys [:mode, :caller, :depth]
  defstruct [:mode, :caller, :depth]

  @type t :: %__MODULE__{
          mode: :get | :set,
          caller: QuickBEAM.VM.Frame.t(),
          depth: non_neg_integer()
        }
end
