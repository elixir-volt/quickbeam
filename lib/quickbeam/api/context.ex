defmodule QuickBEAM.API.Context do
  @moduledoc """
  Installation context passed to `QuickBEAM.API` `install/1` callbacks.
  """

  @type t :: %__MODULE__{
          runtime: QuickBEAM.runtime(),
          scope: QuickBEAM.API.scope_def(),
          data: term(),
          opts: keyword()
        }

  @enforce_keys [:runtime, :scope, :opts]
  defstruct [:runtime, :scope, :data, opts: []]
end
