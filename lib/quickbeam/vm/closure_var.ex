defmodule QuickBEAM.VM.ClosureVar do
  @moduledoc "JavaScript closure capture metadata."

  defstruct [:name, :var_idx, :closure_type, :is_const, :is_lexical, :var_kind]
end
