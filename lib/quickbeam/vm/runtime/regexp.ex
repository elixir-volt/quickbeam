defmodule QuickBEAM.VM.Runtime.RegExp do
  @moduledoc "Defines the VM representation of a JavaScript regular expression."

  @enforce_keys [:source, :bytecode]
  defstruct [:source, :bytecode]

  @type t :: %__MODULE__{source: String.t(), bytecode: binary()}
end
