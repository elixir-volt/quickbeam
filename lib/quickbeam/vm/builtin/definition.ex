defmodule QuickBEAM.VM.Builtin.Definition do
  @moduledoc "Declarative installation metadata for an ECMAScript builtin."

  @type descriptor :: %{
          optional(:writable) => boolean(),
          optional(:enumerable) => boolean(),
          optional(:configurable) => boolean()
        }

  @type prototype_property :: %{
          key: term(),
          value: term(),
          descriptor: descriptor()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          constructor: (list(), term() -> term()),
          length: non_neg_integer() | nil,
          phase: atom(),
          prototype_parent: :object | nil,
          constructor_descriptor: descriptor(),
          prototype_descriptor: descriptor(),
          prototype_properties: [prototype_property()],
          realm_intrinsic: atom() | nil,
          auto_install?: boolean()
        }

  defstruct name: nil,
            constructor: nil,
            length: nil,
            phase: :runtime,
            prototype_parent: :object,
            constructor_descriptor: %{writable: true, enumerable: false, configurable: true},
            prototype_descriptor: %{writable: false, enumerable: false, configurable: false},
            prototype_properties: [],
            realm_intrinsic: nil,
            auto_install?: true
end
