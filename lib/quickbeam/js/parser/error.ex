defmodule QuickBEAM.JS.Parser.Error do
  @moduledoc "Structured syntax error produced by the JavaScript parser."

  @enforce_keys [:message, :line, :column, :offset]
  defstruct [:message, :line, :column, :offset]

  @type t :: %__MODULE__{
          message: binary(),
          line: pos_integer(),
          column: non_neg_integer(),
          offset: non_neg_integer()
        }
end
