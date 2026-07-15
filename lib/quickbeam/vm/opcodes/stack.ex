defmodule QuickBEAM.VM.Opcodes.Stack do
  @moduledoc """
  Executes literal and operand-stack QuickJS opcode families.

  The module applies canonical compact stack transformations and returns a
  `:next` action so the interpreter remains the sole owner of instruction
  stepping and resource accounting.
  """

  alias QuickBEAM.VM.{Execution, Frame, StackState}

  @opcodes [
    :push_i32,
    :push_i8,
    :push_i16,
    :push_bigint_i32,
    :undefined,
    :null,
    :push_false,
    :push_true,
    :push_this,
    :push_const,
    :push_const8,
    :drop,
    :dup,
    :dup1,
    :dup2,
    :dup3,
    :nip,
    :nip_catch,
    :nip1,
    :swap,
    :swap2,
    :perm3,
    :perm4,
    :perm5,
    :rot3l,
    :rot3r,
    :rot4l,
    :rot5l,
    :insert2,
    :insert3
  ]

  @type action :: {:next, Frame.t(), Execution.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported literal or stack-manipulation opcode."
  @spec execute(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute(name, operands, %Frame{} = frame, %Execution{} = execution)
      when name in @opcodes and is_list(operands) do
    {:ok, stack} =
      StackState.execute(name, operands, frame.stack, frame.this, frame.function.constants)

    {:next, %{frame | stack: stack}, execution}
  end
end
