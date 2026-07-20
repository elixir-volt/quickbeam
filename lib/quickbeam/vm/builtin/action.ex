defmodule QuickBEAM.VM.Builtin.Action do
  @moduledoc "Wraps a validated resumable action returned by a builtin handler."

  @enforce_keys [:value]
  defstruct [:value]

  @type t :: %__MODULE__{value: term()}
end
