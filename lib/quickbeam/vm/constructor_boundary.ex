defmodule QuickBEAM.VM.ConstructorBoundary do
  @moduledoc """
  Tracks completion of a JavaScript constructor invocation.

  Primitive constructor returns are replaced with the allocated instance, while
  object returns become the result of the `new` expression.
  """

  @enforce_keys [:instance, :caller, :depth]
  defstruct [:instance, :caller, :depth]

  @type t :: %__MODULE__{
          instance: QuickBEAM.VM.Reference.t(),
          caller: QuickBEAM.VM.Frame.t() | QuickBEAM.VM.NativeFrame.t(),
          depth: non_neg_integer()
        }
end
