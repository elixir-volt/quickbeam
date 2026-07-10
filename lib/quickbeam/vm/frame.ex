defmodule QuickBEAM.VM.Frame do
  @moduledoc false

  @enforce_keys [:function, :callable, :locals, :args]
  defstruct [:function, :callable, :locals, :args, :this, closure_refs: {}, pc: 0, stack: []]

  @type t :: %__MODULE__{
          function: QuickBEAM.VM.Function.t(),
          callable: term(),
          closure_refs: tuple(),
          locals: tuple(),
          args: tuple(),
          this: term(),
          pc: non_neg_integer(),
          stack: [term()]
        }
end
