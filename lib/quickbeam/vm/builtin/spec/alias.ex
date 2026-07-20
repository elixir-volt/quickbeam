defmodule QuickBEAM.VM.Builtin.Spec.Alias do
  @moduledoc "Defines a builtin property that aliases another property on the same object."

  @enforce_keys [:key, :target]
  defstruct [:key, :target, writable: true, enumerable: false, configurable: true]

  @type t :: %__MODULE__{
          key: term(),
          target: term(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end
