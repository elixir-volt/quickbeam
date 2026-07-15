defmodule QuickBEAM.VM.Compiler.ModulePool.Lease do
  @moduledoc """
  Grants one evaluation process temporary access to a compiled module slot.

  Leases are owner-local and opaque. A module may be invoked only while its
  lease is valid; callers must not retain the module or construct leases.
  """

  @enforce_keys [:pool, :module, :key, :epoch, :generation, :token, :owner]
  defstruct [:pool, :module, :key, :epoch, :generation, :token, :owner]

  @type t :: %__MODULE__{
          pool: pid(),
          module: module(),
          key: binary(),
          epoch: pos_integer(),
          generation: pos_integer(),
          token: reference(),
          owner: pid()
        }
end
