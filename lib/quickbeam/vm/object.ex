defmodule QuickBEAM.VM.Object do
  @moduledoc "Defines an object stored in an evaluation-owned VM heap."

  defstruct kind: :ordinary,
            prototype: nil,
            properties: %{},
            property_order: [],
            extensible: true,
            length: 0,
            length_writable: true,
            callable: nil,
            internal: nil

  @type kind :: :ordinary | :array | :function | :map | :promise | :regexp | :set
  @type t :: %__MODULE__{
          kind: kind(),
          prototype: QuickBEAM.VM.Reference.t() | nil,
          properties: %{
            optional(term()) => QuickBEAM.VM.Property.t() | {term()}
          },
          property_order: [term()],
          extensible: boolean(),
          length: non_neg_integer(),
          length_writable: boolean(),
          callable: term() | nil,
          internal: term()
        }
end
