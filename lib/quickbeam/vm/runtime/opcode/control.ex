defmodule QuickBEAM.VM.Runtime.Opcode.Control do
  @moduledoc """
  Executes branch, catch, return, throw, and await opcode families.

  The module chooses explicit control actions but leaves frame execution,
  instruction stepping, async scheduling, and exception unwinding to the
  interpreter and their canonical semantic layers.
  """

  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Promise.Reference, as: PromiseReference
  alias QuickBEAM.VM.Runtime.Value

  @opcodes [
    :catch,
    :gosub,
    :ret,
    :if_false,
    :if_false8,
    :if_true,
    :if_true8,
    :goto,
    :goto8,
    :goto16,
    :return,
    :return_undef,
    :return_async,
    :throw,
    :await
  ]

  @type action ::
          {:next, Frame.t(), State.t()}
          | {:run, Frame.t(), State.t()}
          | {:return, term(), State.t()}
          | {:return_async, term(), State.t()}
          | {:throw, term(), Frame.t(), State.t()}
          | {:await_promise, PromiseReference.t(), Frame.t(), State.t()}
          | {:await_legacy, reference(), Frame.t(), State.t()}
          | {:await_immediate, {:ok, term()} | {:error, term()}, Frame.t(), State.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported control-flow opcode."
  @spec execute(atom(), [term()], Frame.t(), State.t()) :: action()
  def execute(:catch, [target], frame, execution),
    do: next(%{frame | stack: [{:catch, target} | frame.stack]}, execution)

  def execute(:gosub, [target], frame, execution) do
    return_address = {:return_address, frame.pc + 1}
    {:run, %{frame | pc: target, stack: [return_address | frame.stack]}, execution}
  end

  def execute(:ret, [], %{stack: [{:return_address, target} | stack]} = frame, execution),
    do: {:run, %{frame | pc: target, stack: stack}, execution}

  def execute(name, [target], %{stack: [value | stack]} = frame, execution)
      when name in [:if_false, :if_false8] do
    pc = if Value.truthy?(value), do: frame.pc + 1, else: target
    {:run, %{frame | pc: pc, stack: stack}, execution}
  end

  def execute(name, [target], %{stack: [value | stack]} = frame, execution)
      when name in [:if_true, :if_true8] do
    pc = if Value.truthy?(value), do: target, else: frame.pc + 1
    {:run, %{frame | pc: pc, stack: stack}, execution}
  end

  def execute(name, [target], frame, execution) when name in [:goto, :goto8, :goto16],
    do: {:run, %{frame | pc: target}, execution}

  def execute(:return, [], %{stack: [value | _stack]}, execution),
    do: {:return, value, execution}

  def execute(:return_undef, [], _frame, execution),
    do: {:return, :undefined, execution}

  def execute(:return_async, [], %{stack: [value | _stack]}, execution),
    do: {:return_async, value, execution}

  def execute(:throw, [], %{stack: [value | stack]} = frame, execution),
    do: {:throw, value, %{frame | stack: stack}, execution}

  def execute(:await, [], %{stack: [%PromiseReference{} = promise | stack]} = frame, execution),
    do: {:await_promise, promise, %{frame | stack: stack}, execution}

  def execute(:await, [], %{stack: [{:pending, reference} | stack]} = frame, execution),
    do: {:await_legacy, reference, %{frame | stack: stack}, execution}

  def execute(:await, [], %{stack: [{:resolved, value} | stack]} = frame, execution),
    do: {:await_immediate, {:ok, value}, %{frame | stack: stack}, execution}

  def execute(:await, [], %{stack: [{:rejected, reason} | stack]} = frame, execution),
    do: {:await_immediate, {:error, reason}, %{frame | stack: stack}, execution}

  def execute(:await, [], %{stack: [value | stack]} = frame, execution),
    do: {:await_immediate, {:ok, value}, %{frame | stack: stack}, execution}

  defp next(frame, execution), do: {:next, frame, execution}
end
