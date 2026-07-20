defmodule QuickBEAM.VM.Compiler.Analysis.Block do
  @moduledoc """
  Represents one verified QuickJS basic block for compiler lowering.

  Instruction entries contain canonical opcode names and instruction-index
  targets, never serialized byte offsets.
  """

  @enforce_keys [:start_pc, :end_pc, :instructions, :successors, :predecessors]
  defstruct [:start_pc, :end_pc, :instructions, :successors, :predecessors]

  @type instruction :: {non_neg_integer(), atom(), [term()]}

  @type t :: %__MODULE__{
          start_pc: non_neg_integer(),
          end_pc: non_neg_integer(),
          instructions: [instruction()],
          successors: [non_neg_integer()],
          predecessors: [non_neg_integer()]
        }
end
