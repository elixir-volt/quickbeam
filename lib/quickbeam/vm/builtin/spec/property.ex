defmodule QuickBEAM.VM.Builtin.Spec.Property do
  @moduledoc "Defines a declarative JavaScript builtin data property."

  @enforce_keys [:key, :value]
  defstruct [:key, :value, writable: false, enumerable: false, configurable: false]

  @type t :: %__MODULE__{
          key: term(),
          value: term(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end
