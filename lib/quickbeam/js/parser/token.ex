defmodule QuickBEAM.JS.Parser.Token do
  @moduledoc "Token emitted by the JavaScript lexer."

  @enforce_keys [:type, :value, :raw, :start, :finish, :line, :column]
  defstruct [
    :type,
    :value,
    :raw,
    :start,
    :finish,
    :line,
    :column,
    before_line_terminator?: false
  ]

  @type type ::
          :identifier
          | :keyword
          | :number
          | :string
          | :boolean
          | :null
          | :punctuator
          | :eof

  @type t :: %__MODULE__{
          type: type(),
          value: term(),
          raw: binary(),
          start: non_neg_integer(),
          finish: non_neg_integer(),
          line: pos_integer(),
          column: non_neg_integer(),
          before_line_terminator?: boolean()
        }
end
