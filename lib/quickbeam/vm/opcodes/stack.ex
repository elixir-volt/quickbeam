defmodule QuickBEAM.VM.Opcodes.Stack do
  @moduledoc """
  Executes literal and operand-stack QuickJS opcode families.

  The module only transforms explicit frames. It returns a `:next` action so the
  interpreter remains the sole owner of instruction stepping and resource
  accounting.
  """

  alias QuickBEAM.VM.{Execution, Frame}

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
  def execute(name, [value], frame, execution)
      when name in [:push_i32, :push_i8, :push_i16],
      do: push(frame, execution, value)

  def execute(:push_bigint_i32, [value], frame, execution),
    do: push(frame, execution, {:bigint, value})

  def execute(:undefined, [], frame, execution), do: push(frame, execution, :undefined)
  def execute(:null, [], frame, execution), do: push(frame, execution, nil)
  def execute(:push_false, [], frame, execution), do: push(frame, execution, false)
  def execute(:push_true, [], frame, execution), do: push(frame, execution, true)
  def execute(:push_this, [], frame, execution), do: push(frame, execution, frame.this)

  def execute(name, [index], frame, execution) when name in [:push_const, :push_const8],
    do: push(frame, execution, Enum.at(frame.function.constants, index))

  def execute(:drop, [], %{stack: [_value | stack]} = frame, execution),
    do: next(%{frame | stack: stack}, execution)

  def execute(:dup, [], %{stack: [value | _]} = frame, execution),
    do: next(%{frame | stack: [value | frame.stack]}, execution)

  def execute(:dup1, [], %{stack: [a, b | stack]} = frame, execution),
    do: next(%{frame | stack: [a, b, b | stack]}, execution)

  def execute(:dup2, [], %{stack: [a, b | stack]} = frame, execution),
    do: next(%{frame | stack: [a, b, a, b | stack]}, execution)

  def execute(:dup3, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: next(%{frame | stack: [a, b, c, a, b, c | stack]}, execution)

  def execute(name, [], %{stack: [a, _b | stack]} = frame, execution)
      when name in [:nip, :nip_catch],
      do: next(%{frame | stack: [a | stack]}, execution)

  def execute(:nip1, [], %{stack: [a, b, _c | stack]} = frame, execution),
    do: next(%{frame | stack: [a, b | stack]}, execution)

  def execute(:swap, [], %{stack: [a, b | stack]} = frame, execution),
    do: next(%{frame | stack: [b, a | stack]}, execution)

  def execute(:swap2, [], %{stack: [a, b, c, d | stack]} = frame, execution),
    do: next(%{frame | stack: [c, d, a, b | stack]}, execution)

  def execute(:perm3, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: next(%{frame | stack: [a, c, b | stack]}, execution)

  def execute(:perm4, [], %{stack: [a, b, c, d | stack]} = frame, execution),
    do: next(%{frame | stack: [a, c, d, b | stack]}, execution)

  def execute(:perm5, [], %{stack: [a, b, c, d, e | stack]} = frame, execution),
    do: next(%{frame | stack: [a, c, d, e, b | stack]}, execution)

  def execute(:rot3l, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: next(%{frame | stack: [c, a, b | stack]}, execution)

  def execute(:rot3r, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: next(%{frame | stack: [b, c, a | stack]}, execution)

  def execute(:rot4l, [], %{stack: [a, b, c, d | stack]} = frame, execution),
    do: next(%{frame | stack: [d, a, b, c | stack]}, execution)

  def execute(:rot5l, [], %{stack: [a, b, c, d, e | stack]} = frame, execution),
    do: next(%{frame | stack: [e, a, b, c, d | stack]}, execution)

  def execute(:insert2, [], %{stack: [a, b | stack]} = frame, execution),
    do: next(%{frame | stack: [a, b, a | stack]}, execution)

  def execute(:insert3, [], %{stack: [a, b, c | stack]} = frame, execution),
    do: next(%{frame | stack: [a, b, c, a | stack]}, execution)

  defp push(frame, execution, value), do: next(%{frame | stack: [value | frame.stack]}, execution)
  defp next(frame, execution), do: {:next, frame, execution}
end
