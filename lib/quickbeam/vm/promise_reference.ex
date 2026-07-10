defmodule QuickBEAM.VM.PromiseReference do
  @moduledoc false

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: non_neg_integer()}
end
