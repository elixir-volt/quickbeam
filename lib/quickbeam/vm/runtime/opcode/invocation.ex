defmodule QuickBEAM.VM.Runtime.Opcode.Invocation do
  @moduledoc """
  Executes ordinary, method, tail, and constructor call opcodes.

  The module decodes call operands from explicit frame stacks and prepares
  invocation actions. Callable resolution and call planning remain in
  `QuickBEAM.VM.Invocation`; the interpreter remains responsible for advancing
  continuation frames and executing invocation actions.
  """

  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Heap
  alias QuickBEAM.VM.Runtime.Invocation
  alias QuickBEAM.VM.Runtime.Iterator
  alias QuickBEAM.VM.Runtime.State

  @opcodes [
    :apply,
    :call,
    :tail_call,
    :call_method,
    :tail_call_method,
    :call_constructor,
    :check_ctor,
    :init_ctor
  ]

  @type action ::
          {:invoke, term(), [term()], term(), Frame.t(), State.t(), boolean()}
          | {:invoke_constructor, term(), [term()], term(), Frame.t(), State.t()}
          | {:invoke_super_constructor, term(), [term()], term(), Frame.t(), State.t()}
          | {:throw, term(), Frame.t(), State.t()}
          | {:error, term(), State.t()}

  @doc "Returns the opcode names handled by this family."
  @spec opcodes() :: [atom()]
  def opcodes, do: @opcodes

  @doc "Executes one supported invocation opcode."
  @spec execute(atom(), [term()], Frame.t(), State.t()) :: action()
  def execute(:check_ctor, [], %Frame{callable: callable, this: this} = frame, execution) do
    with %QuickBEAM.VM.Runtime.Reference{} <- callable,
         {:ok, %{internal: :class_constructor}} <- Heap.fetch_object(execution, callable),
         %QuickBEAM.VM.Runtime.Reference{} <- this,
         {:ok, %{internal: :constructor_instance}} <- Heap.fetch_object(execution, this) do
      {:next, frame, execution}
    else
      _other -> {:throw, {:type_error, :class_constructor_requires_new}, frame, execution}
    end
  end

  def execute(
        :apply,
        [constructor?],
        %Frame{stack: [argument_list, this, callable | stack]} = frame,
        execution
      ) do
    case Iterator.values(argument_list, execution) do
      {:ok, arguments} when constructor? == 0 ->
        {:invoke, callable, arguments, this, %{frame | stack: stack}, execution, false}

      {:ok, arguments} when constructor? == 1 ->
        if Invocation.constructable?(callable, execution) do
          prototype = Invocation.constructor_prototype(callable, execution)

          {instance, execution} =
            Heap.allocate(execution, :ordinary,
              prototype: prototype,
              internal: :constructor_instance
            )

          {:invoke_constructor, callable, arguments, instance, %{frame | stack: stack}, execution}
        else
          {:throw, {:type_error, :not_a_constructor}, frame, execution}
        end

      {:error, reason} ->
        {:throw, {:type_error, reason}, frame, execution}

      {:resumable} ->
        {:throw, {:type_error, :unsupported_resumable_apply}, frame, execution}
    end
  end

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

  def execute(
        :init_ctor,
        [],
        %Frame{callable: %QuickBEAM.VM.Runtime.Reference{} = callable} = frame,
        execution
      ) do
    with {:ok, parent} <- Heap.prototype(execution, callable),
         true <- Invocation.constructable?(parent, execution) do
      prototype = Invocation.constructor_prototype(callable, execution)

      {instance, execution} =
        Heap.allocate(execution, :ordinary,
          prototype: prototype,
          internal: :constructor_instance
        )

      {:invoke_super_constructor, parent, Tuple.to_list(frame.args), instance, frame, execution}
    else
      _other -> {:throw, {:type_error, :invalid_super_constructor}, frame, execution}
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
