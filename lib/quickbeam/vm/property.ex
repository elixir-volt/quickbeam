defmodule QuickBEAM.VM.Property do
  @moduledoc "Defines a JavaScript property value and its descriptor flags."

  defstruct kind: :data,
            value: :undefined,
            writable: true,
            enumerable: true,
            configurable: true,
            getter: nil,
            setter: nil

  @type kind :: :data | :accessor
  @type t :: %__MODULE__{
          kind: kind(),
          value: term(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean(),
          getter: term() | nil,
          setter: term() | nil
        }
end
