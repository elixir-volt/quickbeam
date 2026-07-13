defmodule QuickBEAM.VM.Builtin.Spec do
  @moduledoc """
  Defines immutable, compile-time-validated metadata for one JavaScript builtin.

  Specs are installed deterministically into each owner-local execution. They do
  not contain heap references or captured functions.
  """

  alias QuickBEAM.VM.Builtin.{FunctionSpec, PropertySpec}

  @enforce_keys [:name, :module, :kind]
  defstruct [
    :name,
    :module,
    :constructor,
    :profile,
    kind: :object,
    length: 0,
    statics: [],
    prototype: []
  ]

  @type kind :: :object | :constructor | :extension
  @type t :: %__MODULE__{
          name: String.t(),
          module: module(),
          kind: kind(),
          constructor: atom() | nil,
          profile: atom(),
          length: non_neg_integer(),
          statics: [FunctionSpec.t() | PropertySpec.t()],
          prototype: [FunctionSpec.t() | PropertySpec.t()]
        }
end

defmodule QuickBEAM.VM.Builtin.FunctionSpec do
  @moduledoc "Defines a declarative JavaScript builtin function property."

  @enforce_keys [:key, :handler]
  defstruct [:key, :handler, length: 0, writable: true, enumerable: false, configurable: true]

  @type t :: %__MODULE__{
          key: term(),
          handler: atom(),
          length: non_neg_integer(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end

defmodule QuickBEAM.VM.Builtin.PropertySpec do
  @moduledoc "Defines a declarative JavaScript builtin data property."

  @enforce_keys [:key, :value]
  defstruct [:key, :value, writable: false, enumerable: false, configurable: false]

  @type t :: %__MODULE__{
          key: term(),
          value: term(),
          writable: boolean(),
          enumerable: boolean(),
          configurable: boolean()
        }
end
