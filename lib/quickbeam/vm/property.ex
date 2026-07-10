defmodule QuickBEAM.VM.Property do
  @moduledoc "Defines a JavaScript property value and its descriptor flags."

  defstruct value: :undefined, writable: true, enumerable: true, configurable: true

  @type t :: %__MODULE__{
          value: term(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end
