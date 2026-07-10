defmodule QuickBEAM.VM.Object do
  @moduledoc "Defines an object stored in an evaluation-owned VM heap."

  defstruct kind: :ordinary,
            prototype: nil,
            properties: %{},
            extensible: true,
            length: 0,
            callable: nil,
            internal: nil

  @type kind :: :ordinary | :array | :promise | :set
  @type t :: %__MODULE__{
          kind: kind(),
          prototype: QuickBEAM.VM.Reference.t() | nil,
          properties: %{optional(term()) => QuickBEAM.VM.Property.t()},
          extensible: boolean(),
          length: non_neg_integer(),
          callable: term() | nil,
          internal: term()
        }
end
