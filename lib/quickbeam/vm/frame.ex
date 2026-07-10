defmodule QuickBEAM.VM.Frame do
  @moduledoc false

  @enforce_keys [:function, :locals, :args]
  defstruct [:function, :locals, :args, :this, pc: 0, stack: []]

  @type t :: %__MODULE__{
          function: QuickBEAM.VM.Function.t(),
          locals: tuple(),
          args: tuple(),
          this: term(),
          pc: non_neg_integer(),
          stack: [term()]
        }
end
