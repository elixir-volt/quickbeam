defmodule QuickBEAM.VM.Program do
  @moduledoc "Compiled or decoded JavaScript program: atom table plus top-level VM value."

  @type t :: %__MODULE__{}
  defstruct [:version, :atoms, :value]
end
