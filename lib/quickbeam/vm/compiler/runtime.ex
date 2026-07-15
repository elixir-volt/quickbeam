defmodule QuickBEAM.VM.Compiler.Runtime do
  @moduledoc """
  Defines the versioned semantic ABI available to generated BEAM modules.

  The initial ABI supports exact block charging, explicit deoptimization, and
  verified pure stack, local, value, and branch operations. Implementations
  delegate to canonical VM opcode and value layers rather than duplicating
  JavaScript semantics.
  """

  alias QuickBEAM.VM.Compiler.{Contract, Deopt}
  alias QuickBEAM.VM.Compiler.ModulePool.Lease
  alias QuickBEAM.VM.Execution
  alias QuickBEAM.VM.Frame
  alias QuickBEAM.VM.Opcodes.{Control, Locals, Stack, Values}
  alias QuickBEAM.VM.Value

  @stack_operations Stack.opcodes()
  @local_operations [:get_arg, :put_arg, :set_arg, :get_loc, :get_loc0_loc1, :put_loc, :set_loc]
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

  @type action ::
          {:ok, Frame.t(), Execution.t()}
          | {:deopt, Deopt.t()}
          | {:error, term(), Execution.t()}
          | {:error, term()}

  @doc "Returns the generated-code runtime ABI version."
  @spec version() :: pos_integer()
  def version, do: Contract.runtime_abi_version()

  @doc "Charges a guaranteed straight-line block or deoptimizes before it."
  @spec charge_block(Lease.t(), Frame.t(), Execution.t(), pos_integer()) :: action()
  def charge_block(%Lease{owner: owner}, _frame, _execution, _count) when owner != self(),
    do: {:error, :compiler_lease_owner_mismatch}

  def charge_block(_lease, _frame, %Execution{memory_exceeded: true} = execution, _count),
    do: {:error, {:limit_exceeded, :memory_bytes, execution.memory_limit}, execution}

  def charge_block(
        %Lease{},
        %Frame{} = frame,
        %Execution{remaining_steps: remaining} = execution,
        count
      )
      when is_integer(count) and count > 0 and remaining >= count do
    {:ok, frame, %{execution | remaining_steps: remaining - count}}
  end

  def charge_block(%Lease{} = lease, %Frame{} = frame, %Execution{} = execution, count)
      when is_integer(count) and count > 0,
      do: deopt(:step_boundary, lease, frame, execution)

  def charge_block(_lease, _frame, _execution, count),
    do: {:error, {:invalid_compiler_step_charge, count}}

  @doc "Constructs a validated owner-local before-instruction deoptimization action."
  @spec deopt(Deopt.reason(), Lease.t(), Frame.t(), Execution.t()) :: action()
  def deopt(_reason, %Lease{owner: owner}, _frame, _execution) when owner != self(),
    do: {:error, :compiler_lease_owner_mismatch}

  def deopt(reason, %Lease{} = lease, %Frame{} = frame, %Execution{} = execution) do
    case Deopt.new(reason, lease.key, lease.epoch, lease.generation, frame, execution) do
      {:ok, deopt} -> {:deopt, deopt}
      {:error, error} -> {:error, {:invalid_compiler_deopt, error}}
    end
  end

  @doc "Executes one verified pure operand-stack instruction and advances the PC."
  @spec execute_stack(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute_stack(name, operands, %Frame{} = frame, %Execution{} = execution)
      when name in @stack_operations and is_list(operands),
      do: name |> Stack.execute(operands, frame, execution) |> advance_action()

  def execute_stack(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_stack_operation, name, operands}}

  @doc "Executes one verified pure local or argument instruction and advances the PC."
  @spec execute_local(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute_local(name, operands, %Frame{} = frame, %Execution{} = execution)
      when name in @local_operations and is_list(operands),
      do: name |> Locals.execute(operands, frame, execution) |> advance_action()

  def execute_local(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_local_operation, name, operands}}

  @doc "Executes one verified primitive value instruction and advances the PC."
  @spec execute_value(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute_value(name, operands, %Frame{} = frame, %Execution{} = execution)
      when name in @value_operations and is_list(operands),
      do: name |> Values.execute(operands, frame, execution) |> advance_action()

  def execute_value(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_value_operation, name, operands}}

  @doc "Executes one verified conditional or unconditional branch instruction."
  @spec execute_branch(atom(), [term()], Frame.t(), Execution.t()) :: action()
  def execute_branch(name, operands, %Frame{} = frame, %Execution{} = execution)
      when name in @branch_operations and is_list(operands),
      do: name |> Control.execute(operands, frame, execution) |> branch_action()

  def execute_branch(name, operands, _frame, _execution),
    do: {:error, {:unsupported_compiler_branch_operation, name, operands}}

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
