defmodule QuickBEAM.VM.VarDef do
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
end
