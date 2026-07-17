defmodule QuickBEAM.VM.Runtime.Reference do
  @moduledoc "Identifies an object in one evaluation-owned VM heap."

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: non_neg_integer()}
end
