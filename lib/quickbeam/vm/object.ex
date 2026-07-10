defmodule QuickBEAM.VM.Object do
  @moduledoc false

  defstruct kind: :ordinary, prototype: nil, properties: %{}, extensible: true, length: 0

  @type kind :: :ordinary | :array | :promise
  @type t :: %__MODULE__{
          kind: kind(),
          prototype: QuickBEAM.VM.Reference.t() | nil,
          properties: %{optional(term()) => QuickBEAM.VM.Property.t()},
          extensible: boolean(),
          length: non_neg_integer()
        }
end
