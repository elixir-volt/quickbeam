defmodule QuickBEAM.VM.Builtin.Spec.Accessor do
  @moduledoc "Defines a declarative JavaScript builtin accessor property."

  @enforce_keys [:key]
  defstruct [:key, :getter, :setter, enumerable: false, configurable: true]

  @type t :: %__MODULE__{
          key: term(),
          getter: atom() | nil,
          setter: atom() | nil,
          enumerable: boolean(),
          configurable: boolean()
        }
end
