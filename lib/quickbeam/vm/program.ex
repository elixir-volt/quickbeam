defmodule QuickBEAM.VM.Program do
  @moduledoc "Compiled or decoded JavaScript program: atom table plus top-level VM value."

  @enforce_keys [:version, :fingerprint, :atoms, :root]
  defstruct [:version, :fingerprint, :atoms, :root]

  @type t :: %__MODULE__{
          version: non_neg_integer(),
          fingerprint: String.t(),
          atoms: tuple(),
          root: term()
        }
end
