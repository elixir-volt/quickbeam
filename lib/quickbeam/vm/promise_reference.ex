defmodule QuickBEAM.VM.PromiseReference do
  @moduledoc "Identifies a Promise in one evaluation's Promise store."

  @enforce_keys [:id]
  defstruct [:id]

  @type t :: %__MODULE__{id: non_neg_integer()}
end
