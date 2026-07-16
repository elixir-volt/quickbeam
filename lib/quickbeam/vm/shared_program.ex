defmodule QuickBEAM.VM.SharedProgram do
  @moduledoc """
  A lightweight handle to a verified immutable program in bounded shared storage.

  Handles can be copied cheaply between request processes. The underlying
  decoded program remains in a fixed `QuickBEAM.VM.ProgramStore` slot until
  explicitly released with `QuickBEAM.VM.release_program/1`.
  """

  @enforce_keys [:key]
  defstruct [:key]

  @type t :: %__MODULE__{key: binary()}
end
