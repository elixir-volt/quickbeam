defmodule QuickBEAM.VM.Runtime.Boundary.Constructor do
  @moduledoc """
  Tracks completion of a JavaScript constructor invocation.

  Primitive constructor returns are replaced with the allocated instance, while
  object returns become the result of the `new` expression.
  """

  @enforce_keys [:instance, :caller, :depth]
  defstruct [:instance, :caller, :depth]

  @type t :: %__MODULE__{
          instance: QuickBEAM.VM.Runtime.Reference.t(),
          caller: QuickBEAM.VM.Runtime.Frame.t() | QuickBEAM.VM.Runtime.Frame.Native.t(),
          depth: non_neg_integer()
        }
end
