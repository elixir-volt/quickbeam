defmodule QuickBEAM.VM.Property do
  @moduledoc false

  defstruct value: :undefined, writable: true, enumerable: true, configurable: true

  @type t :: %__MODULE__{
          value: term(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end
