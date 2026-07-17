defmodule QuickBEAM.VM.Compiler.Profile.Pure do
  @moduledoc """
  Lowers verified v26 basic blocks to the first bounded compiler profile.

  Generated modules contain specialized block and instruction clauses but route
  every operation through the canonical runtime ABI. Unsupported or resumable
  instructions remain explicit before-instruction deopt boundaries.
  """

  alias QuickBEAM.VM.Bytecode.Opcode
  alias QuickBEAM.VM.Bytecode.Verifier.Stack
  alias QuickBEAM.VM.Compiler.Analysis.ControlFlow, as: CFG
  alias QuickBEAM.VM.Compiler.Code.Template
  alias QuickBEAM.VM.Compiler.Profile.Scalar
  alias QuickBEAM.VM.Compiler.Runtime
  alias QuickBEAM.VM.Program.Function
  alias QuickBEAM.VM.Runtime.Opcode.Invocation

  @max_block_instruction_count 256
  @max_block_count 4_096
  @max_lowered_instruction_count 4_096
  @max_region_operations 32
  @suspension_operations [:await] ++ Invocation.opcodes()
  @core_scalar_operations %{
    get_loc_check: :local,
    post_dec: :value,
    post_inc: :value
  }
  @extended_scalar_operations %{
    check_define_var: :global,
    define_func: :global,
    define_var: :global,
    get_var: :global,
    get_var_undef: :global,
    push_atom_value: :global,
    put_var: :global,
    put_var_init: :global,
    call: :invocation,
    call_method: :invocation,
    get_array_el: :object,
    get_field: :object,
    get_field2: :object,
    get_length: :object
  }
  @scalar_operations Map.merge(@core_scalar_operations, @extended_scalar_operations)
  @line 1

  @doc "Rejects obviously too-small non-loop candidates before artifact hashing."
  @spec candidate?(Function.t(), non_neg_integer(), :pure_v1 | :scalar_v1) :: boolean()
  def candidate?(%Function{instructions: instructions}, minimum, profile)
      when is_tuple(instructions) and is_integer(minimum) and minimum >= 0 and
             profile in [:pure_v1, :scalar_v1] do
    minimum <= 1 or tuple_size(instructions) >= minimum or backward_branch?(instructions)
  end

  @doc "Emits one bounded scalar entry region from an oversized function."
  @spec prepare_region(Function.t(), non_neg_integer(), :pure_v1 | :scalar_v1) ::
          {:ok, Template.t(), non_neg_integer()} | {:skip, non_neg_integer()} | {:error, term()}
  def prepare_region(%Function{} = function, entry_pc, profile)
      when is_integer(entry_pc) and entry_pc >= 0 and profile in [:pure_v1, :scalar_v1] do
    with {:ok, plan, levels} <- analyze_plan(function, profile) do
      region = select_region(plan, entry_pc)
      count = lowered_operation_count(region)

      case Scalar.lower_region(function, region, levels) do
        {:ok, template} when count > 0 -> {:ok, template, count}
        _not_eligible -> {:skip, count}
      end
    end
  end

  @doc "Returns the deterministic pure-block execution plan for one function."
  @spec plan(Function.t()) :: {:ok, Runtime.plan()} | {:error, term()}
  def plan(%Function{} = function) do
    with {:ok, plan, _levels} <- analyze_plan(function, :pure_v1), do: {:ok, plan}
  end

  @doc "Returns bounded scalar eligibility for a verified function and profile."
  @spec scalar_eligibility(Function.t(), :pure_v1 | :scalar_v1) ::
          :eligible | {:ineligible, atom()} | {:error, term()}
  def scalar_eligibility(%Function{} = function, profile)
      when profile in [:pure_v1, :scalar_v1] do
    with {:ok, plan, levels} <- analyze_plan(function, profile) do
      Scalar.eligibility(function, plan, levels)
    end
  end

  @doc "Emits specialized generated-module forms for the bounded pure profile."
  @spec lower(Function.t()) :: {:ok, Template.t()} | {:error, term()}
  def lower(%Function{} = function) do
    with {:ok, plan, levels} <- analyze_plan(function, :pure_v1),
         do: lower_plan(function, plan, levels, :pure_v1)
  end

  @doc "Selects functions with a useful entry prefix and emits their validated plan."
  @spec prepare(Function.t(), non_neg_integer(), :pure_v1 | :scalar_v1) ::
          {:ok, Template.t(), non_neg_integer()} | {:skip, non_neg_integer()} | {:error, term()}
  def prepare(function, minimum, profile \\ :pure_v1)

  def prepare(%Function{} = function, minimum, profile)
      when is_integer(minimum) and minimum >= 0 and profile in [:pure_v1, :scalar_v1] do
    with {:ok, analyzed_plan, levels} <- analyze_plan(function, profile) do
      template = template(function, analyzed_plan, levels, profile)
      plan = if scalar_template?(template), do: analyzed_plan, else: generic_plan(analyzed_plan)
      count = lowered_operation_count(plan)
      entry_count = entry_operation_count(plan)

      if eligible_template?(template, plan, count, entry_count, minimum),
        do: {:ok, template, count},
        else: {:skip, count}
    end
  end

  defp analyze_plan(function, profile) do
    with {:ok, analysis} <- Stack.analyze(function),
         true <- analysis.maximum == function.stack_size,
         {:ok, blocks} <- CFG.analyze(function),
         plan <- build_plan(blocks, profile),
         :ok <- validate_plan_size(plan) do
      {:ok, plan, analysis.levels}
    else
      false -> {:error, {:stack_size_mismatch, function.stack_size}}
      {:error, _reason} = error -> error
    end
  end

  @spec lower_plan(Function.t(), Runtime.plan(), map(), :pure_v1 | :scalar_v1) ::
          {:ok, Template.t()}
  defp lower_plan(function, plan, levels, profile),
    do: {:ok, template(function, plan, levels, profile)}

  defp entry_operation_count(plan) do
    case Map.get(plan, 0) do
      {operations, _reason} -> length(operations)
      nil -> 0
    end
  end

  @doc "Reports whether a template uses bounded scalar block forms."
  @spec scalar_template?(Template.t()) :: boolean()
  def scalar_template?(%Template{forms: forms}),
    do: Enum.any?(forms, &match?({:function, _, :block, 7, _}, &1))

  defp lowered_operation_count(plan) do
    Enum.reduce(plan, 0, fn {_pc, {operations, _reason}}, count -> count + length(operations) end)
  end

  defp eligible_template?(template, plan, count, entry_count, minimum) do
    cond do
      scalar_template?(template) and extended_scalar_plan?(plan) -> loop_plan?(plan)
      scalar_template?(template) -> count >= minimum or (minimum > 0 and loop_plan?(plan))
      true -> entry_count >= minimum
    end
  end

  defp extended_scalar_plan?(plan) do
    Enum.any?(plan, fn {_pc, {operations, _reason}} ->
      Enum.any?(operations, fn {family, _name, _operands} -> family in [:object, :invocation] end)
    end)
  end

  defp backward_branch?(instructions) do
    instructions
    |> Tuple.to_list()
    |> Enum.with_index()
    |> Enum.any?(fn {{opcode, operands}, pc} ->
      case Opcode.info(opcode) do
        {name, _size, _pops, _pushes, _format}
        when name in [:goto, :goto8, :goto16, :if_false, :if_false8, :if_true, :if_true8] ->
          match?([target | _] when is_integer(target) and target <= pc, operands)

        _info ->
          false
      end
    end)
  end

  defp loop_plan?(plan) do
    Enum.any?(plan, fn {pc, {operations, _reason}} ->
      Enum.any?(operations, fn
        {:branch, _name, [target]} -> target <= pc
        _operation -> false
      end)
    end)
  end

  defp select_region(plan, entry_pc) do
    case Map.get(plan, entry_pc) do
      {operations, reason} when operations != [] ->
        selected = operations |> Enum.take(@max_region_operations) |> drop_terminal_branch()

        selected_reason =
          if length(selected) < length(operations) or reason == :continue,
            do: :unsupported_semantics,
            else: reason

        if selected == [], do: %{}, else: %{entry_pc => {selected, selected_reason}}

      _missing_or_unsupported_entry ->
        %{}
    end
  end

  defp drop_terminal_branch(operations) do
    case List.last(operations) do
      {:branch, _name, _operands} -> Enum.drop(operations, -1)
      _operation -> operations
    end
  end

  defp build_plan(blocks, :pure_v1), do: Map.new(blocks, &plan_block(&1, :pure_v1))

  defp build_plan(blocks, :scalar_v1),
    do: blocks |> Enum.flat_map(&plan_block_segments/1) |> Map.new()

  defp plan_block_segments(block) do
    block.instructions
    |> split_scalar_segments([], [])
    |> Enum.map(fn instructions ->
      first_pc = instructions |> hd() |> elem(0)
      plan_block(%{block | start_pc: first_pc, instructions: instructions}, :scalar_v1)
    end)
  end

  defp split_scalar_segments([], [], segments), do: Enum.reverse(segments)

  defp split_scalar_segments([], current, segments),
    do: Enum.reverse([Enum.reverse(current) | segments])

  defp split_scalar_segments([instruction | instructions], current, segments) do
    cond do
      not supported_instruction?(instruction, :scalar_v1) ->
        segments = if current == [], do: segments, else: [Enum.reverse(current) | segments]
        split_scalar_segments(instructions, [], [[instruction] | segments])

      preflight_instruction?(instruction) ->
        segments = if current == [], do: segments, else: [Enum.reverse(current) | segments]
        split_scalar_segments(instructions, [], [[instruction] | segments])

      invocation_instruction?(instruction) ->
        current = [instruction | current]
        split_scalar_segments(instructions, [], [Enum.reverse(current) | segments])

      true ->
        split_scalar_segments(instructions, [instruction | current], segments)
    end
  end

  defp preflight_instruction?({_pc, name, _operands}),
    do: name in [:get_array_el, :get_field, :get_field2, :get_length, :get_var]

  defp invocation_instruction?({_pc, name, _operands}), do: name in [:call, :call_method]

  defp plan_block(block, profile) do
    {supported, remainder} =
      Enum.split_while(block.instructions, &supported_instruction?(&1, profile))

    capped? = length(supported) > @max_block_instruction_count
    supported = Enum.take(supported, @max_block_instruction_count)
    operations = Enum.map(supported, &operation(&1, profile))
    next_instruction = Enum.at(block.instructions, length(supported))
    reason = boundary_reason(operations, remainder, next_instruction, capped?)
    {block.start_pc, {operations, reason}}
  end

  @doc "Reports whether one canonical instruction belongs to a bounded profile."
  @spec supported_instruction?({non_neg_integer(), atom(), [term()]}, :pure_v1 | :scalar_v1) ::
          boolean()
  def supported_instruction?({_pc, name, _operands}, profile)
      when profile in [:pure_v1, :scalar_v1] do
    scalar_operations =
      if profile == :scalar_v1, do: @scalar_operations, else: @core_scalar_operations

    Map.has_key?(scalar_operations, name) or
      match?({:ok, _family}, Runtime.operation_family(name))
  end

  defp operation({_pc, name, operands}, profile) do
    scalar_operations =
      if profile == :scalar_v1, do: @scalar_operations, else: @core_scalar_operations

    family =
      case Map.fetch(scalar_operations, name) do
        {:ok, family} -> family
        :error -> name |> Runtime.operation_family() |> elem(1)
      end

    {family, name, operands}
  end

  defp boundary_reason(_operations, _remainder, _next_instruction, true),
    do: :unsupported_semantics

  defp boundary_reason([], _remainder, {_pc, name, _operands}, false),
    do: deopt_reason(name)

  defp boundary_reason(_operations, [_unsupported | _], {_pc, name, _operands}, false),
    do: deopt_reason(name)

  defp boundary_reason(_operations, [], nil, false), do: :continue

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

  defp template(function, plan, levels, _profile) do
    case Scalar.lower(function, plan, levels) do
      {:ok, template} -> template
      :not_eligible -> generic_template(generic_plan(plan))
    end
  end

  defp generic_plan(plan) do
    Map.new(plan, fn {pc, {operations, reason}} ->
      {supported, remainder} =
        Enum.split_while(operations, fn {_family, name, _operands} ->
          not Map.has_key?(@scalar_operations, name)
        end)

      reason =
        cond do
          remainder != [] -> :unsupported_opcode
          reason == :continue -> :unsupported_semantics
          true -> reason
        end

      {pc, {supported, reason}}
    end)
  end

  defp generic_template(plan) do
    step_forms = if has_slow_operations?(plan), do: [step_form(plan)], else: []

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

  defp has_slow_operations?(plan),
    do:
      Enum.any?(plan, fn {_pc, {operations, _reason}} ->
        operations != [] and not fast_operations?(operations)
      end)

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

  defp block_clause(pc, {operations, reason}) do
    if fast_operations?(operations) do
      fast_block_clause(pc, operations, reason)
    else
      stepped_block_clause(pc, operations)
    end
  end

  defp fast_block_clause(pc, operations, reason) do
    lease = variable(:Lease)
    frame = variable(:Frame)
    execution = variable(:Execution)
    next_frame = variable(:NextFrame)
    next_execution = variable(:NextExecution)
    action = variable(:Action)

    execute =
      remote_call(Runtime, :execute_fast_block, [
        lease,
        frame,
        execution,
        :erl_parse.abstract(operations)
      ])

    body =
      case_expression(execute, [
        clause(
          [tuple([atom(:ok), next_frame, next_execution])],
          [boundary_call(reason, lease, next_frame, next_execution)]
        ),
        clause([action], [action])
      ])

    clause([integer(pc), lease, frame, execution], [body])
  end

  defp stepped_block_clause(pc, operations) do
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
      |> Enum.reject(fn {_pc, {operations, _reason}} -> fast_operations?(operations) end)
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
        [boundary_call(reason)]
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

  defp fast_operations?(operations), do: operations != []

  defp boundary_call(reason),
    do: boundary_call(reason, variable(:Lease), variable(:Frame), variable(:Execution))

  defp boundary_call(:continue, lease, frame, execution) do
    pc = remote_call(Runtime, :frame_pc, [frame])
    local_call(:block, [pc, lease, frame, execution])
  end

  defp boundary_call(reason, lease, frame, execution),
    do: deopt_call(reason, lease, frame, execution)

  defp deopt_call(reason),
    do: deopt_call(reason, variable(:Lease), variable(:Frame), variable(:Execution))

  defp deopt_call(reason, lease, frame, execution) do
    remote_call(Runtime, :deopt, [atom(reason), lease, frame, execution])
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
