defmodule QuickBEAM.VM.Compiler.Lowering.PureV1 do
  @moduledoc """
  Lowers verified v26 basic blocks to the first bounded compiler profile.

  The initial profile emits one generated entry function that delegates a
  bounded pure block plan to the canonical compiler runtime ABI. Unsupported or
  resumable instructions remain explicit before-instruction deopt boundaries.
  """

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.GeneratedModule.Template
  alias QuickBEAM.VM.Compiler.Runtime
  alias QuickBEAM.VM.{Function, StackVerifier}
  alias QuickBEAM.VM.Opcodes.Invocation

  @max_block_instruction_count 256
  @suspension_operations [:await] ++ Invocation.opcodes()
  @line 1

  @doc "Returns the deterministic pure-block execution plan for one function."
  @spec plan(Function.t()) :: {:ok, Runtime.plan()} | {:error, term()}
  def plan(%Function{} = function) do
    with :ok <- StackVerifier.verify(function),
         {:ok, blocks} <- CFG.analyze(function) do
      {:ok, Map.new(blocks, &plan_block/1)}
    end
  end

  @doc "Emits a generated-module template for the bounded pure profile."
  @spec lower(Function.t()) :: {:ok, Template.t()} | {:error, term()}
  def lower(%Function{} = function) do
    with {:ok, plan} <- plan(function) do
      {:ok, template(plan)}
    end
  end

  defp plan_block(block) do
    {supported, remainder} = Enum.split_while(block.instructions, &supported_instruction?/1)
    capped? = length(supported) > @max_block_instruction_count
    supported = Enum.take(supported, @max_block_instruction_count)
    operations = Enum.map(supported, &operation/1)
    next_instruction = Enum.at(block.instructions, length(supported))
    reason = boundary_reason(operations, remainder, next_instruction, capped?)
    {block.start_pc, {operations, reason}}
  end

  defp supported_instruction?({_pc, name, _operands}),
    do: match?({:ok, _family}, Runtime.operation_family(name))

  defp operation({_pc, name, operands}) do
    {:ok, family} = Runtime.operation_family(name)
    {family, name, operands}
  end

  defp boundary_reason(_operations, _remainder, _next_instruction, true),
    do: :unsupported_semantics

  defp boundary_reason([], _remainder, {_pc, name, _operands}, false),
    do: deopt_reason(name)

  defp boundary_reason(_operations, [_unsupported | _], {_pc, name, _operands}, false),
    do: deopt_reason(name)

  defp boundary_reason(_operations, _remainder, _next_instruction, false),
    do: :unsupported_semantics

  defp deopt_reason(name) when name in @suspension_operations, do: :suspension_boundary
  defp deopt_reason(_name), do: :unsupported_opcode

  defp template(plan) do
    lease = {:var, @line, :Lease}
    frame = {:var, @line, :Frame}
    execution = {:var, @line, :Execution}

    call =
      {:call, @line, {:remote, @line, {:atom, @line, Runtime}, {:atom, @line, :execute_plan}},
       [lease, frame, execution, :erl_parse.abstract(plan)]}

    %Template{
      forms: [
        {:attribute, @line, :module, Template.placeholder_module()},
        {:attribute, @line, :export, [run: 3]},
        {:function, @line, :run, 3, [{:clause, @line, [lease, frame, execution], [], [call]}]},
        {:eof, @line}
      ]
    }
  end
end
