defmodule QuickBEAM.VM.Builtin.Spec.Function do
  @moduledoc "Defines a declarative JavaScript builtin function property."

  @enforce_keys [:key, :handler]
  defstruct [:key, :handler, length: 0, writable: true, enumerable: false, configurable: true]

  @type t :: %__MODULE__{
          key: term(),
          handler: atom(),
          length: non_neg_integer(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end
