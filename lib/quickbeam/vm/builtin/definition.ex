defmodule QuickBEAM.VM.Builtin.Definition do
  @moduledoc "Declarative installation metadata for an ECMAScript builtin."

  alias QuickBEAM.VM.ObjectModel.PropertyDescriptor

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
          module: module() | nil,
          prototype_parent: :object | nil,
          constructor_descriptor: descriptor(),
          prototype_descriptor: descriptor(),
          prototype_properties: [prototype_property()],
          constructable?: boolean(),
          intrinsic_key: atom() | nil,
          ecma: term(),
          annex: term(),
          after_install: (term() -> term()) | (term(), keyword() -> term()) | nil,
          auto_install?: boolean()
        }

  @constructor_descriptor PropertyDescriptor.constructor()
  @prototype_descriptor PropertyDescriptor.prototype()

  defstruct name: nil,
            constructor: nil,
            length: nil,
            phase: :runtime,
            module: nil,
            prototype_parent: :object,
            constructor_descriptor: @constructor_descriptor,
            prototype_descriptor: @prototype_descriptor,
            prototype_properties: [],
            constructable?: true,
            intrinsic_key: nil,
            ecma: nil,
            annex: nil,
            after_install: nil,
            auto_install?: true
end
