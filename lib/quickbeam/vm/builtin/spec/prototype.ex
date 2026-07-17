defmodule QuickBEAM.VM.Builtin.Spec.Prototype do
  @moduledoc "Defines semantic topology for one JavaScript intrinsic prototype."

  defstruct kind: :ordinary,
            extends: :default,
            default_for: nil,
            callable: nil,
            primitive: nil,
            error_type: nil

  @type t :: %__MODULE__{
          kind: :ordinary | :array | :function,
          extends: :default | nil | String.t(),
          default_for: atom() | nil,
          callable: atom() | nil,
          primitive: {atom(), term()} | nil,
          error_type: String.t() | nil
        }
end
