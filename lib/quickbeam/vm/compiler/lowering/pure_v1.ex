defmodule QuickBEAM.VM.Compiler.Lowering.PureV1 do
  @moduledoc """
  Lowers verified v26 basic blocks to the first bounded compiler profile.

  Generated modules contain specialized block and instruction clauses but route
  every operation through the canonical runtime ABI. Unsupported or resumable
  instructions remain explicit before-instruction deopt boundaries.
  """

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.GeneratedModule.Template
  alias QuickBEAM.VM.Compiler.Runtime
  alias QuickBEAM.VM.{Function, StackVerifier}
  alias QuickBEAM.VM.Opcodes.Invocation

  @max_block_instruction_count 256
  @max_block_count 4_096
  @max_lowered_instruction_count 4_096
  @suspension_operations [:await] ++ Invocation.opcodes()
  @line 1

  @doc "Returns the deterministic pure-block execution plan for one function."
  @spec plan(Function.t()) :: {:ok, Runtime.plan()} | {:error, term()}
  def plan(%Function{} = function) do
    with :ok <- StackVerifier.verify(function),
         {:ok, blocks} <- CFG.analyze(function),
         plan = Map.new(blocks, &plan_block/1),
         :ok <- validate_plan_size(plan) do
      {:ok, plan}
    end
  end

  @doc "Emits specialized generated-module forms for the bounded pure profile."
  @spec lower(Function.t()) :: {:ok, Template.t()} | {:error, term()}
  def lower(%Function{} = function) do
    with {:ok, plan} <- plan(function), do: lower_plan(plan)
  end

  @doc "Selects functions with a useful entry prefix and emits their validated plan."
  @spec prepare(Function.t(), non_neg_integer()) ::
          {:ok, Template.t(), non_neg_integer()} | {:skip, non_neg_integer()} | {:error, term()}
  def prepare(%Function{} = function, minimum) when is_integer(minimum) and minimum >= 0 do
    with {:ok, plan} <- plan(function) do
      count = entry_operation_count(plan)

      if count >= minimum,
        do: {:ok, template(plan), count},
        else: {:skip, count}
    end
  end

  @spec lower_plan(Runtime.plan()) :: {:ok, Template.t()}
  defp lower_plan(plan), do: {:ok, template(plan)}

  defp entry_operation_count(plan) do
    case Map.get(plan, 0) do
      {operations, _reason} -> length(operations)
      nil -> 0
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

  defp validate_plan_size(plan) when map_size(plan) > @max_block_count,
    do: {:error, {:compiler_resource_limit, :blocks, map_size(plan), @max_block_count}}

  defp validate_plan_size(plan) do
    count =
      Enum.reduce(plan, 0, fn {_pc, {operations, _reason}}, count ->
        count + length(operations)
      end)

    if count <= @max_lowered_instruction_count,
      do: :ok,
      else:
        {:error,
         {:compiler_resource_limit, :lowered_instructions, count, @max_lowered_instruction_count}}
  end

  defp template(plan) do
    step_forms = if has_operations?(plan), do: [step_form(plan)], else: []

    %Template{
      forms:
        [
          {:attribute, @line, :module, Template.placeholder_module()},
          {:attribute, @line, :export, [run: 3]},
          run_form(),
          block_form(plan)
        ] ++
          step_forms ++ [{:eof, @line}]
    }
  end

  defp has_operations?(plan),
    do: Enum.any?(plan, fn {_pc, {operations, _reason}} -> operations != [] end)

  defp run_form do
    lease = variable(:Lease)
    frame = variable(:Frame)
    execution = variable(:Execution)
    pc = remote_call(Runtime, :frame_pc, [frame])
    body = local_call(:block, [pc, lease, frame, execution])
    function(:run, 3, [clause([lease, frame, execution], [body])])
  end

  defp block_form(plan) do
    clauses =
      plan
      |> Enum.sort_by(fn {pc, _block} -> pc end)
      |> Enum.map(fn {pc, block} -> block_clause(pc, block) end)

    fallback =
      clause(
        [variable(:_PC), variable(:Lease), variable(:Frame), variable(:Execution)],
        [deopt_call(:unsupported_semantics)]
      )

    function(:block, 4, clauses ++ [fallback])
  end

  defp block_clause(pc, {[], reason}) do
    clause(
      [integer(pc), variable(:Lease), variable(:Frame), variable(:Execution)],
      [deopt_call(reason)]
    )
  end

  defp block_clause(pc, {operations, _reason}) do
    lease = variable(:Lease)
    frame = variable(:Frame)
    execution = variable(:Execution)
    next_frame = variable(:NextFrame)
    next_execution = variable(:NextExecution)
    action = variable(:Action)

    charge =
      remote_call(Runtime, :charge_block, [lease, frame, execution, integer(length(operations))])

    body =
      case_expression(charge, [
        clause(
          [tuple([atom(:ok), next_frame, next_execution])],
          [local_call(:step, [step_id(pc, 0), lease, next_frame, next_execution])]
        ),
        clause([action], [action])
      ])

    clause([integer(pc), lease, frame, execution], [body])
  end

  defp step_form(plan) do
    clauses =
      plan
      |> Enum.sort_by(fn {pc, _block} -> pc end)
      |> Enum.flat_map(fn {pc, {operations, reason}} -> step_clauses(pc, operations, reason) end)

    fallback =
      clause(
        [variable(:_Step), variable(:_Lease), variable(:_Frame), variable(:_Execution)],
        [tuple([atom(:error), atom(:invalid_compiler_step)])]
      )

    function(:step, 4, clauses ++ [fallback])
  end

  defp step_clauses(pc, operations, reason) do
    operation_clauses =
      operations
      |> Enum.with_index()
      |> Enum.map(fn {operation, index} -> operation_clause(pc, index, operation) end)

    final =
      clause(
        [
          step_id(pc, length(operations)),
          variable(:Lease),
          variable(:Frame),
          variable(:Execution)
        ],
        [deopt_call(reason)]
      )

    operation_clauses ++ [final]
  end

  defp operation_clause(pc, index, {family, name, operands}) do
    lease = variable(:Lease)
    frame = variable(:Frame)
    execution = variable(:Execution)
    next_frame = variable(:NextFrame)
    next_execution = variable(:NextExecution)
    action = variable(:Action)

    execute =
      remote_call(Runtime, family_function(family), [
        atom(name),
        :erl_parse.abstract(operands),
        frame,
        execution
      ])

    body =
      case_expression(execute, [
        clause(
          [tuple([atom(:ok), next_frame, next_execution])],
          [local_call(:step, [step_id(pc, index + 1), lease, next_frame, next_execution])]
        ),
        clause([action], [action])
      ])

    clause([step_id(pc, index), lease, frame, execution], [body])
  end

  defp family_function(:stack), do: :execute_stack
  defp family_function(:local), do: :execute_local
  defp family_function(:value), do: :execute_value
  defp family_function(:branch), do: :execute_branch

  defp deopt_call(reason) do
    remote_call(Runtime, :deopt, [
      atom(reason),
      variable(:Lease),
      variable(:Frame),
      variable(:Execution)
    ])
  end

  defp step_id(pc, index), do: tuple([integer(pc), integer(index)])
  defp function(name, arity, clauses), do: {:function, @line, name, arity, clauses}
  defp clause(patterns, body), do: {:clause, @line, patterns, [], body}
  defp case_expression(expression, clauses), do: {:case, @line, expression, clauses}
  defp local_call(name, arguments), do: {:call, @line, atom(name), arguments}

  defp remote_call(module, name, arguments) do
    {:call, @line, {:remote, @line, atom(module), atom(name)}, arguments}
  end

  defp variable(name), do: {:var, @line, name}
  defp tuple(elements), do: {:tuple, @line, elements}
  defp integer(value), do: {:integer, @line, value}
  defp atom(value), do: {:atom, @line, value}
end
