defmodule QuickBEAM.VM.Runtime.Thrown do
  @moduledoc """
  Carries a raw JavaScript thrown value together with preserved async frames.

  The wrapper stays internal to an evaluation until an uncaught exception is
  converted to `QuickBEAM.JSError` at the public boundary.
  """

  @enforce_keys [:value, :frames]
  defstruct [:value, :frames]

  @type t :: %__MODULE__{value: term(), frames: [QuickBEAM.JSError.frame()]}
end
