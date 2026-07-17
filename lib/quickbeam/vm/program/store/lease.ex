defmodule QuickBEAM.VM.Program.Store.Lease do
  @moduledoc """
  Identifies one bounded lease on an immutable pinned VM program.

  Leases contain only fixed-slot metadata. Program terms remain in
  `:persistent_term`; evaluation callers fetch a shared literal reference before
  spawning their workers.
  """

  @enforce_keys [:id, :key, :slot, :token]
  defstruct [:id, :key, :slot, :token]

  @type t :: %__MODULE__{
          id: reference(),
          key: binary(),
          slot: non_neg_integer(),
          token: reference()
        }
end
