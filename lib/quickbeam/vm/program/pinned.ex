defmodule QuickBEAM.VM.Program.Pinned do
  @moduledoc """
  A lightweight handle to a verified immutable program pinned in bounded storage.

  Handles can be copied cheaply between request processes. The underlying
  decoded program remains in a fixed `QuickBEAM.VM.Program.Store` slot until
  explicitly removed with `QuickBEAM.VM.unpin/1`. A supervised store restart
  restores valid slots. Once unpinning begins, new evaluations and replacement
  pins are rejected while existing evaluation leases finish.
  """

  @enforce_keys [:key]
  defstruct [:key]

  @type t :: %__MODULE__{key: binary()}
end
