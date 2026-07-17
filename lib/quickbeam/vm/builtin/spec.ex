defmodule QuickBEAM.VM.Builtin.Spec do
  @moduledoc """
  Defines immutable, compile-time-validated metadata for one JavaScript builtin.

  Specs are installed deterministically into each owner-local execution. They do
  not contain heap references or captured functions.
  """

  alias QuickBEAM.VM.Builtin.Spec.{Accessor, Alias, Function, Property, Prototype}

  @enforce_keys [:name, :module, :kind]
  defstruct [
    :name,
    :module,
    :constructor,
    prototype_spec: %Prototype{},
    profiles: [:core],
    depends_on: [],
    kind: :namespace,
    length: 0,
    statics: [],
    prototype: []
  ]

  @type kind :: :namespace | :function | :constructor | :intrinsic
  @type t :: %__MODULE__{
          name: String.t(),
          module: module(),
          kind: kind(),
          constructor: atom() | nil,
          prototype_spec: Prototype.t(),
          profiles: [atom()],
          depends_on: [String.t()],
          length: non_neg_integer(),
          statics: [Function.t() | Property.t() | Accessor.t() | Alias.t()],
          prototype: [Function.t() | Property.t() | Accessor.t() | Alias.t()]
        }
end
