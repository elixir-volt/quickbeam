defmodule QuickBEAM.VM.Opcodes.Invocation do
  @moduledoc """
  Executes ordinary, method, tail, and constructor call opcodes.

  The module decodes call operands from explicit frame stacks and prepares
  invocation actions. Callable resolution and call planning remain in
  `QuickBEAM.VM.Invocation`; the interpreter remains responsible for advancing
  continuation frames and executing invocation actions.
  """

  alias QuickBEAM.VM.{Execution, Frame, Heap, Invocation}

  @opcodes [:call, :tail_call, :call_method, :tail_call_method, :call_constructor]

  @type action ::
          {:invoke, term(), [term()], term(), Frame.t(), Execution.t(), boolean()}
          | {:invoke_constructor, term(), [term()], term(), Frame.t(), Execution.t()}
          | {:throw, term(), Frame.t(), Execution.t()}
          | {:error, term(), Execution.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported invocation opcode."
  @spec execute(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute(name, [argument_count], %Frame{stack: stack} = frame, execution)
      when name in [:call, :tail_call] do
    {arguments, callable_and_rest} = Enum.split(stack, argument_count)

    case callable_and_rest do
      [callable | rest] ->
        tail? = name == :tail_call
        caller = %{frame | stack: rest}
        {:invoke, callable, Enum.reverse(arguments), :undefined, caller, execution, tail?}

      _ ->
        {:error, {:invalid_stack, :call}, execution}
    end
  end

  def execute(name, [argument_count], %Frame{stack: stack} = frame, execution)
      when name in [:call_method, :tail_call_method] do
    {arguments, callable_and_this} = Enum.split(stack, argument_count)

    case callable_and_this do
      [callable, this | rest] ->
        tail? = name == :tail_call_method
        caller = %{frame | stack: rest}
        {:invoke, callable, Enum.reverse(arguments), this, caller, execution, tail?}

      _ ->
        {:error, {:invalid_stack, :call_method}, execution}
    end
  end

  def execute(:call_constructor, [argument_count], %Frame{stack: stack} = frame, execution) do
    {arguments, constructor_and_new_target} = Enum.split(stack, argument_count)

    case constructor_and_new_target do
      [_new_target, constructor | rest] ->
        if Invocation.constructable?(constructor, execution) do
          prototype = Invocation.constructor_prototype(constructor, execution)

          {instance, execution} =
            Heap.allocate(execution, :ordinary,
              prototype: prototype,
              internal: :constructor_instance
            )

          caller = %{frame | stack: rest}
          {:invoke_constructor, constructor, Enum.reverse(arguments), instance, caller, execution}
        else
          {:throw, {:type_error, :not_a_constructor}, frame, execution}
        end

      _ ->
        {:error, {:invalid_stack, :call_constructor}, execution}
    end
  end
end
