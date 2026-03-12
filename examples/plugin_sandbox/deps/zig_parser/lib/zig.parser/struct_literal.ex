defmodule Zig.Parser.StructLiteral do
  defstruct [:type, :values, :location]

  @type t :: %__MODULE__{
          type: atom | nil,
          values: %{optional(atom) => any}
        }
end
