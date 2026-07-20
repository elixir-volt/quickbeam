defmodule QuickBEAM.VM.Compiler.Runtime do
  @moduledoc """
  Defines the versioned semantic ABI available to generated BEAM modules.

  The ABI supports exact block charging, explicit deoptimization, and verified
  stack, local, global, property, value, branch, and invocation operations. Implementations
  delegate to canonical VM opcode and value layers rather than duplicating
  JavaScript semantics.
  """

  alias QuickBEAM.VM.Compiler.Contract
  alias QuickBEAM.VM.Compiler.Deopt
  alias QuickBEAM.VM.Compiler.Pool.Lease
  alias QuickBEAM.VM.Runtime.Frame
  alias QuickBEAM.VM.Runtime.Opcode.Control
  alias QuickBEAM.VM.Runtime.Opcode.Local, as: Locals
  alias QuickBEAM.VM.Runtime.Opcode.Stack
  alias QuickBEAM.VM.Runtime.Opcode.Value, as: Values
  alias QuickBEAM.VM.Runtime.Property
  alias QuickBEAM.VM.Runtime.Stack, as: OperandStack
  alias QuickBEAM.VM.Runtime.State
  alias QuickBEAM.VM.Runtime.Value

  @stack_operations Stack.opcodes()
  @local_operations [
    :get_arg,
    :put_arg,
    :set_arg,
    :get_loc,
    :get_loc0_loc1,
    :inc_loc,
    :dec_loc,
    :add_loc,
    :put_loc,
    :set_loc,
    :set_loc_uninitialized,
    :put_loc_check_init,
    :put_loc_check
  ]
  @value_operations [
    :add,
    :sub,
    :mul,
    :div,
    :mod,
    :pow,
    :lt,
    :lte,
    :gt,
    :gte,
    :eq,
    :neq,
    :strict_eq,
    :strict_neq,
    :and,
    :or,
    :xor,
    :shl,
    :sar,
    :shr,
    :neg,
    :plus,
    :not,
    :lnot,
    :inc,
    :dec,
    :is_undefined_or_null,
    :is_undefined,
    :is_null
  ]
  @branch_operations [:if_false, :if_false8, :if_true, :if_true8, :goto, :goto8, :goto16]
  @max_block_instruction_count 256

  @type operation :: {:stack | :local | :value | :branch, atom(), [term()]}
  @type block_boundary :: Deopt.reason() | :continue
  @type plan :: %{optional(non_neg_integer()) => {[operation()], block_boundary()}}

  @type action ::
          {:ok, Frame.t(), State.t()}
          | {:deopt, Deopt.t()}
          | {:invoke, term(), [term()], term(), Frame.t(), State.t(), false}
          | {:error, term(), State.t()}
          | {:error, term()}

  @doc "Returns the generated-code runtime ABI version."
  @spec version() :: pos_integer()
  def version, do: Contract.runtime_abi_version()

  @doc "Returns compact immutable fields used by scalar generated blocks."
  @spec frame_state(Frame.t()) :: {non_neg_integer(), tuple(), tuple(), [term()]}
  def frame_state(%Frame{} = frame), do: {frame.pc, frame.args, frame.locals, frame.stack}

  @doc "Returns the current frame receiver for scalar literal lowering."
  @spec frame_this(Frame.t()) :: term()
  def frame_this(%Frame{this: this}), do: this

  @doc "Returns one verified function constant for scalar literal lowering."
  @spec frame_constant(Frame.t(), non_neg_integer()) :: term()
  def frame_constant(%Frame{function: function}, index), do: Enum.at(function.constants, index)

  @doc "Returns the current verified instruction index from a canonical frame."
  @spec frame_pc(Frame.t()) :: non_neg_integer()
  def frame_pc(%Frame{pc: pc}), do: pc

  @doc "Returns the pure compiler family for a supported canonical opcode."
  @spec operation_family(atom()) :: {:ok, :stack | :local | :value | :branch} | :error
  def operation_family(name) when name in @stack_operations, do: {:ok, :stack}
  def operation_family(name) when name in @local_operations, do: {:ok, :local}
  def operation_family(name) when name in @value_operations, do: {:ok, :value}
  def operation_family(name) when name in @branch_operations, do: {:ok, :branch}
  def operation_family(_name), do: :error

  @doc "Executes one bounded lowered block and deoptimizes at its next boundary."
  @spec execute_plan(Lease.t(), Frame.t(), State.t(), plan()) :: action()
  def execute_plan(%Lease{} = lease, %Frame{} = frame, %State{} = execution, plan)
      when is_map(plan) do
    case Map.fetch(plan, frame.pc) do
      {:ok, {[], reason}} ->
        deopt(reason, lease, frame, execution)

      {:ok, {operations, reason}}
      when is_list(operations) and length(operations) <= @max_block_instruction_count ->
        with {:ok, frame, execution} <-
               charge_block(lease, frame, execution, length(operations)),
             {:ok, frame, execution} <- execute_operations(operations, frame, execution) do
          finish_block(reason, lease, frame, execution, plan)
        end

      {:ok, invalid} ->
        {:error, {:invalid_compiler_block_plan, frame.pc, invalid}}

      :error ->
        deopt(:unsupported_semantics, lease, frame, execution)
    end
  end

  def execute_plan(_lease, _frame, _execution, plan),
    do: {:error, {:invalid_compiler_plan, plan}}

  defp finish_block(:continue, lease, frame, execution, plan),
    do: execute_plan(lease, frame, execution, plan)

  defp finish_block(reason, lease, frame, execution, _plan),
    do: deopt(reason, lease, frame, execution)

  @doc "Charges a scalar block or deoptimizes with its reconstructed before-block state."
  @spec charge_state(Lease.t(), tuple(), State.t(), pos_integer()) ::
          {:ok, tuple()} | action()
  def charge_state(%Lease{owner: owner}, _state, _execution, _count) when owner != self(),
    do: {:error, :compiler_lease_owner_mismatch}

  def charge_state(_lease, _state, %State{memory_exceeded: true} = execution, _count),
    do: {:error, {:limit_exceeded, :memory_bytes, execution.memory_limit}, execution}

  def charge_state(
        %Lease{} = lease,
        {%Frame{} = frame, pc, args, locals, stack},
        %State{remaining_steps: remaining} = execution,
        count
      )
      when is_integer(pc) and pc >= 0 and is_tuple(args) and is_tuple(locals) and is_list(stack) and
             is_integer(count) and count > 0 and remaining >= count do
    charged_execution = %{execution | remaining_steps: remaining - count}
    {:ok, {lease, frame, args, locals, stack, charged_execution}}
  end

  def charge_state(%Lease{} = lease, state, %State{} = execution, count)
      when is_integer(count) and count > 0,
      do: deopt_state(:step_boundary, lease, state, execution)

  def charge_state(_lease, state, _execution, count),
    do: {:error, {:invalid_compiler_scalar_charge, count, state}}

  @doc "Charges a guaranteed straight-line block or deoptimizes before it."
  @spec charge_block(Lease.t(), Frame.t(), State.t(), pos_integer()) :: action()
  def charge_block(%Lease{owner: owner}, _frame, _execution, _count) when owner != self(),
    do: {:error, :compiler_lease_owner_mismatch}

  def charge_block(_lease, _frame, %State{memory_exceeded: true} = execution, _count),
    do: {:error, {:limit_exceeded, :memory_bytes, execution.memory_limit}, execution}

  def charge_block(
        %Lease{},
        %Frame{} = frame,
        %State{remaining_steps: remaining} = execution,
        count
      )
      when is_integer(count) and count > 0 and remaining >= count do
    {:ok, frame, %{execution | remaining_steps: remaining - count}}
  end

  def charge_block(%Lease{} = lease, %Frame{} = frame, %State{} = execution, count)
      when is_integer(count) and count > 0,
      do: deopt(:step_boundary, lease, frame, execution)

  def charge_block(_lease, _frame, _execution, count),
    do: {:error, {:invalid_compiler_step_charge, count}}

  @doc "Constructs a validated owner-local before-instruction deoptimization action."
  @spec deopt(Deopt.reason(), Lease.t(), Frame.t(), State.t()) :: action()
  def deopt(_reason, %Lease{owner: owner}, _frame, _execution) when owner != self(),
    do: {:error, :compiler_lease_owner_mismatch}

  def deopt(reason, %Lease{} = lease, %Frame{} = frame, %State{} = execution) do
    case Deopt.new(reason, lease.key, lease.epoch, lease.generation, frame, execution) do
      {:ok, deopt} -> {:deopt, deopt}
      {:error, error} -> {:error, {:invalid_compiler_deopt, error}}
    end
  end

  @doc "Deoptimizes after rebuilding a canonical frame from bounded scalar state."
  @spec deopt_state(Deopt.reason(), Lease.t(), tuple(), State.t()) :: action()
  def deopt_state(
        reason,
        %Lease{} = lease,
        {%Frame{} = frame, pc, args, locals, stack},
        %State{} = execution
      )
      when is_integer(pc) and pc >= 0 and is_tuple(args) and is_tuple(locals) and is_list(stack) do
    frame = %{
      frame
      | pc: pc,
        args: args,
        locals: locals,
        stack: stack,
        compiler_allow_reentry: scalar_profile?(execution)
    }

    deopt(reason, lease, frame, execution)
  end

  def deopt_state(_reason, _lease, state, _execution),
    do: {:error, {:invalid_compiler_scalar_state, state}}

  @doc "Executes one compact stack/value/branch block with a single frame rebuild."
  @spec execute_fast_block(Lease.t(), Frame.t(), State.t(), [operation()]) :: action()
  def execute_fast_block(%Lease{} = lease, %Frame{} = frame, %State{} = execution, operations)
      when is_list(operations) and length(operations) <= @max_block_instruction_count do
    with {:ok, frame, execution} <- charge_block(lease, frame, execution, length(operations)),
         {:ok, pc, args, locals, stack, execution} <-
           execute_fast_operations(
             operations,
             frame.pc,
             frame.args,
             frame.locals,
             frame.stack,
             frame.this,
             frame.function,
             execution
           ) do
      {:ok, %{frame | pc: pc, args: args, locals: locals, stack: stack}, execution}
    end
  end

  def execute_fast_block(_lease, _frame, _execution, operations),
    do: {:error, {:invalid_compiler_fast_block, operations}}

  @doc "Executes one verified pure operand-stack instruction and advances the PC."
  @spec execute_stack(atom(), [term()], Frame.t(), State.t()) :: action()
  def execute_stack(name, operands, %Frame{} = frame, %State{} = execution)
      when name in @stack_operations and is_list(operands),
      do: name |> Stack.execute(operands, frame, execution) |> advance_action()

  def execute_stack(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_stack_operation, name, operands}}

  @doc "Updates a bounded argument or local tuple without generated tuple-update optimization."
  @spec tuple_put(tuple(), non_neg_integer(), term()) :: tuple()
  def tuple_put(tuple, index, value) when is_tuple(tuple) and is_integer(index) and index >= 0,
    do: put_elem(tuple, index, value)

  @doc "Executes one verified pure local or argument instruction and advances the PC."
  @spec execute_local(atom(), [term()], Frame.t(), State.t()) :: action()
  def execute_local(name, operands, %Frame{} = frame, %State{} = execution)
      when name in @local_operations and is_list(operands),
      do: name |> Locals.execute(operands, frame, execution) |> advance_action()

  def execute_local(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_local_operation, name, operands}}

  @doc "Executes one verified primitive value instruction and advances the PC."
  @spec execute_value(atom(), [term()], Frame.t(), State.t()) :: action()
  def execute_value(name, operands, %Frame{} = frame, %State{} = execution)
      when name in @value_operations and is_list(operands),
      do: name |> Values.execute(operands, frame, execution) |> advance_action()

  def execute_value(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_value_operation, name, operands}}

  @doc "Executes one verified conditional or unconditional branch instruction."
  @spec execute_branch(atom(), [term()], Frame.t(), State.t()) :: action()
  def execute_branch(name, operands, %Frame{} = frame, %State{} = execution)
      when name in @branch_operations and is_list(operands),
      do: name |> Control.execute(operands, frame, execution) |> branch_action()

  def execute_branch(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_branch_operation, name, operands}}

  defp execute_fast_operations(
         [],
         pc,
         args,
         locals,
         stack,
         _this,
         _function,
         execution
       ),
       do: {:ok, pc, args, locals, stack, execution}

  defp execute_fast_operations(
         [{:stack, name, operands} | operations],
         pc,
         args,
         locals,
         stack,
         this,
         function,
         execution
       ) do
    with {:ok, stack} <- OperandStack.execute(name, operands, stack, this, function.constants) do
      execute_fast_operations(
        operations,
        pc + 1,
        args,
        locals,
        stack,
        this,
        function,
        execution
      )
    end
  end

  defp execute_fast_operations(
         [{:local, name, operands} | operations],
         pc,
         args,
         locals,
         stack,
         this,
         function,
         execution
       ) do
    with {:ok, args, locals, stack, execution} <-
           Locals.execute_compact(name, operands, args, locals, stack, execution) do
      execute_fast_operations(
        operations,
        pc + 1,
        args,
        locals,
        stack,
        this,
        function,
        execution
      )
    end
  end

  defp execute_fast_operations(
         [{:value, name, []} | operations],
         pc,
         args,
         locals,
         [right, left | stack],
         this,
         function,
         execution
       )
       when name in [
              :add,
              :sub,
              :mul,
              :div,
              :mod,
              :pow,
              :lt,
              :lte,
              :gt,
              :gte,
              :eq,
              :neq,
              :strict_eq,
              :strict_neq,
              :and,
              :or,
              :xor,
              :shl,
              :sar,
              :shr
            ] do
    value = fast_binary(name, left, right)

    execute_fast_operations(
      operations,
      pc + 1,
      args,
      locals,
      [value | stack],
      this,
      function,
      execution
    )
  end

  defp execute_fast_operations(
         [{:value, name, []} | operations],
         pc,
         args,
         locals,
         [value | stack],
         this,
         function,
         execution
       )
       when name in [
              :neg,
              :plus,
              :not,
              :lnot,
              :inc,
              :dec,
              :is_undefined_or_null,
              :is_undefined,
              :is_null
            ] do
    value = fast_unary(name, value)

    execute_fast_operations(
      operations,
      pc + 1,
      args,
      locals,
      [value | stack],
      this,
      function,
      execution
    )
  end

  defp execute_fast_operations(
         [{:branch, name, [target]} | operations],
         pc,
         args,
         locals,
         [value | stack],
         this,
         function,
         execution
       )
       when name in [:if_false, :if_false8, :if_true, :if_true8] do
    truthy? = Value.truthy?(value)

    target_pc =
      if name in [:if_false, :if_false8] do
        if truthy?, do: pc + 1, else: target
      else
        if truthy?, do: target, else: pc + 1
      end

    execute_fast_operations(
      operations,
      target_pc,
      args,
      locals,
      stack,
      this,
      function,
      execution
    )
  end

  defp execute_fast_operations(
         [{:branch, name, [target]} | operations],
         _pc,
         args,
         locals,
         stack,
         this,
         function,
         execution
       )
       when name in [:goto, :goto8, :goto16],
       do:
         execute_fast_operations(
           operations,
           target,
           args,
           locals,
           stack,
           this,
           function,
           execution
         )

  defp execute_fast_operations(
         [operation | _],
         pc,
         _args,
         _locals,
         stack,
         _this,
         _function,
         _execution
       ),
       do: {:error, {:invalid_compiler_fast_operation, pc, operation, stack}}

  defp fast_binary(:add, left, right) when is_number(left) and is_number(right),
    do: left + right

  defp fast_binary(:sub, left, right) when is_number(left) and is_number(right),
    do: left - right

  defp fast_binary(:mul, left, right) when is_number(left) and is_number(right),
    do: left * right

  defp fast_binary(:mod, left, right)
       when is_integer(left) and is_integer(right) and right != 0,
       do: rem(left, right)

  defp fast_binary(:lt, left, right) when is_number(left) and is_number(right), do: left < right
  defp fast_binary(:lte, left, right) when is_number(left) and is_number(right), do: left <= right
  defp fast_binary(:gt, left, right) when is_number(left) and is_number(right), do: left > right
  defp fast_binary(:gte, left, right) when is_number(left) and is_number(right), do: left >= right
  defp fast_binary(:eq, left, right) when is_number(left) and is_number(right), do: left == right
  defp fast_binary(:neq, left, right) when is_number(left) and is_number(right), do: left != right

  defp fast_binary(:strict_eq, left, right) when is_number(left) and is_number(right),
    do: left == right

  defp fast_binary(:strict_neq, left, right) when is_number(left) and is_number(right),
    do: left != right

  defp fast_binary(name, left, right), do: Value.binary(name, left, right)

  defp fast_unary(:neg, value) when is_number(value), do: -value
  defp fast_unary(:plus, value) when is_number(value), do: value
  defp fast_unary(:inc, value) when is_number(value), do: value + 1
  defp fast_unary(:dec, value) when is_number(value), do: value - 1
  defp fast_unary(:lnot, value), do: not Value.truthy?(value)
  defp fast_unary(:is_undefined_or_null, value), do: value in [:undefined, nil]
  defp fast_unary(:is_undefined, value), do: value == :undefined
  defp fast_unary(:is_null, value), do: is_nil(value)
  defp fast_unary(name, value), do: Value.unary(name, value)

  defp execute_operations([], frame, execution), do: {:ok, frame, execution}

  defp execute_operations([{family, name, operands} | operations], frame, execution) do
    case execute_operation(family, name, operands, frame, execution) do
      {:ok, frame, execution} -> execute_operations(operations, frame, execution)
      action -> action
    end
  end

  defp execute_operation(:stack, name, operands, frame, execution),
    do: execute_stack(name, operands, frame, execution)

  defp execute_operation(:local, name, operands, frame, execution),
    do: execute_local(name, operands, frame, execution)

  defp execute_operation(:value, name, operands, frame, execution),
    do: execute_value(name, operands, frame, execution)

  defp execute_operation(:branch, name, operands, frame, execution),
    do: execute_branch(name, operands, frame, execution)

  defp execute_operation(family, name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_operation, family, name, operands}}

  @doc "Reads one global through the canonical local/global layer."
  @spec global_get(:get_var | :get_var_undef, term(), State.t()) :: {:ok, term()} | :deopt
  def global_get(mode, atom, %State{} = execution) when mode in [:get_var, :get_var_undef] do
    name = Locals.resolve_atom(atom, execution)

    case Locals.read_global(execution, name) do
      {:ok, value} -> {:ok, value}
      :error when mode == :get_var_undef -> {:ok, :undefined}
      :error -> :deopt
    end
  end

  @doc "Writes one global through the canonical local/global layer."
  @spec global_put(term(), term(), State.t()) :: State.t()
  def global_put(atom, value, %State{} = execution) do
    name = Locals.resolve_atom(atom, execution)
    Locals.write_global(execution, name, value)
  end

  @doc "Resolves one decoded atom operand through the canonical local layer."
  @spec resolve_atom(term(), State.t()) :: term()
  def resolve_atom(atom, %State{} = execution), do: Locals.resolve_atom(atom, execution)

  @doc "Reads a non-accessor property or requests before-instruction deoptimization."
  @spec property_get(term(), term(), State.t()) :: {:ok, term()} | :deopt
  def property_get(object, key, %State{} = execution) do
    case Property.get(object, key, execution) do
      {:ok, {:accessor, _getter, _receiver}} -> :deopt
      {:ok, value} -> {:ok, value}
      {:error, _reason} -> :deopt
    end
  end

  @doc "Returns an explicit interpreter-owned invocation from bounded scalar state."
  @spec invoke_state(term(), [term()], term(), tuple(), State.t()) :: action()
  def invoke_state(
        callable,
        arguments,
        this,
        {%Frame{} = frame, pc, args, locals, stack},
        %State{} = execution
      )
      when is_list(arguments) and is_integer(pc) and pc >= 0 and is_tuple(args) and
             is_tuple(locals) and is_list(stack) do
    caller = %{
      frame
      | pc: pc,
        args: args,
        locals: locals,
        stack: stack,
        compiler_allow_reentry: true,
        compiler_entered: false
    }

    {:invoke, callable, arguments, this, caller, execution, false}
  end

  def invoke_state(_callable, _arguments, _this, state, _execution),
    do: {:error, {:invalid_compiler_invocation_state, state}}

  defp scalar_profile?(%State{compiler_context: %{profile: :scalar_v1}}), do: true
  defp scalar_profile?(_execution), do: false

  @doc "Returns canonical JavaScript truthiness for a represented value."
  @spec truthy?(term()) :: boolean()
  def truthy?(value), do: Value.truthy?(value)

  @doc "Applies one canonical primitive unary operation."
  @spec unary(atom(), term()) :: term()
  def unary(operation, value), do: Value.unary(operation, value)

  @doc "Applies one canonical primitive binary operation."
  @spec binary(atom(), term(), term()) :: term()
  def binary(operation, left, right), do: Value.binary(operation, left, right)

  defp advance_action({:next, frame, execution}),
    do: {:ok, %{frame | pc: frame.pc + 1}, execution}

  defp branch_action({:run, frame, execution}), do: {:ok, frame, execution}
end
