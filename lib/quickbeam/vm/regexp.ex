defmodule QuickBEAM.VM.RegExp do
  @moduledoc false

  @enforce_keys [:source, :bytecode]
  defstruct [:source, :bytecode]

  @type t :: %__MODULE__{source: String.t(), bytecode: binary()}
end
