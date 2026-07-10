defmodule QuickBEAM.VM.Thrown do
  @moduledoc false

  @enforce_keys [:value, :frames]
  defstruct [:value, :frames]

  @type t :: %__MODULE__{value: term(), frames: [QuickBEAM.JSError.frame()]}
end
