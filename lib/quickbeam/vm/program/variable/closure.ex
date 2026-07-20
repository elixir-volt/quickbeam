defmodule QuickBEAM.VM.Program.Variable.Closure do
  @moduledoc "JavaScript closure capture metadata."

  defstruct [:name, :var_idx, :closure_type, :is_const, :is_lexical, :var_kind]

  @type t :: %__MODULE__{
          name: String.t(),
          var_idx: non_neg_integer(),
          closure_type: non_neg_integer(),
          is_const: boolean(),
          is_lexical: boolean(),
          var_kind: non_neg_integer()
        }
end
