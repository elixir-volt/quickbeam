defmodule QuickBEAM.WASM.Function do
  @moduledoc """
  A decoded WebAssembly function.

  Contains the function's type signature, local variables, and decoded
  opcode stream. Opcodes use the same `{offset, name, ...operands}` tuple
  format as `QuickBEAM.Bytecode`.
  """

  defstruct [
    :index,
    :name,
    :type_idx,
    params: [],
    results: [],
    locals: [],
    opcodes: []
  ]

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          name: String.t() | nil,
          type_idx: non_neg_integer(),
          params: [atom()],
          results: [atom()],
          locals: [atom()],
          opcodes: [tuple()]
        }
end
