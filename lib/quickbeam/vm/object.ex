defmodule QuickBEAM.VM.Object do
  @moduledoc """
  Defines an object stored in an evaluation-owned VM heap.

  Default data descriptors use the compact `{value}` storage form. Accessors and
  non-default data descriptors retain full `QuickBEAM.VM.Property` structs.
  Callers must use the descriptor helpers instead of depending on either layout.
  """

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
  @type stored_property :: QuickBEAM.VM.Property.t() | {term()}
  @type t :: %__MODULE__{
          kind: kind(),
          prototype: QuickBEAM.VM.Reference.t() | nil,
          properties: %{optional(term()) => stored_property()},
          property_order: [term()],
          extensible: boolean(),
          length: non_neg_integer(),
          length_writable: boolean(),
          callable: term() | nil,
          internal: term()
        }

  @doc "Expands a compact default data property into its canonical descriptor."
  @spec property_descriptor(stored_property() | nil) :: QuickBEAM.VM.Property.t() | nil
  def property_descriptor({value}), do: %QuickBEAM.VM.Property{value: value}
  def property_descriptor(%QuickBEAM.VM.Property{} = property), do: property
  def property_descriptor(nil), do: nil

  @doc "Tests whether a stored property is enumerable without forcing callers to know its layout."
  @spec property_enumerable?(stored_property()) :: boolean()
  def property_enumerable?({_value}), do: true
  def property_enumerable?(%QuickBEAM.VM.Property{enumerable: enumerable}), do: enumerable
end
