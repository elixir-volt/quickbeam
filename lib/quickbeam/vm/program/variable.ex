defmodule QuickBEAM.VM.Program.Variable do
  @moduledoc "JavaScript local variable definition metadata."

  defstruct [
    :name,
    :scope_level,
    :scope_next,
    :var_kind,
    :is_const,
    :is_lexical,
    :is_captured,
    :var_ref_idx
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          scope_level: non_neg_integer(),
          scope_next: integer(),
          var_kind: non_neg_integer(),
          is_const: boolean(),
          is_lexical: boolean(),
          is_captured: boolean(),
          var_ref_idx: non_neg_integer() | nil
        }
end
