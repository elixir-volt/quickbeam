defmodule QuickBEAM.VM.Compiler.Lowering.ScalarBlocks do
  @moduledoc """
  Emits bounded scalar block forms for functions whose locals cannot become cells.

  Operand-stack values remain generated BEAM expressions within a block, locals
  and arguments remain tuples, and canonical value helpers are called directly.
  Canonical frames are rebuilt only at explicit deoptimization boundaries.
  """

  alias QuickBEAM.VM.Compiler.GeneratedModule.Template
  alias QuickBEAM.VM.Compiler.Runtime
  alias QuickBEAM.VM.Function

  @line 1
  @max_stack_depth 64
  @max_scalar_operations 64
  @max_scalar_blocks 16
  @stack_variables List.to_tuple(
                     for index <- 0..(@max_stack_depth - 1), do: :"_CompilerStack#{index}"
                   )
  @left_variables List.to_tuple(for index <- 0..255, do: :"_CompilerLeft#{index}")
  @right_variables List.to_tuple(for index <- 0..255, do: :"_CompilerRight#{index}")
  @value_variables List.to_tuple(for index <- 0..255, do: :"_CompilerValue#{index}")
  @property_variables List.to_tuple(for index <- 0..255, do: :"_CompilerProperty#{index}")
  @global_variables List.to_tuple(for index <- 0..255, do: :"_CompilerGlobal#{index}")
  @execution_variables List.to_tuple(for index <- 0..255, do: :"_CompilerExecution#{index}")

  @type plan :: Runtime.plan()

  @doc "Emits scalar forms when stack depth and capture ownership are statically bounded."
  @spec lower(Function.t(), plan(), map()) :: {:ok, Template.t()} | :not_eligible
  def lower(%Function{} = function, plan, levels) when is_map(plan) and is_map(levels),
    do: lower(function, plan, levels, :beam)

  @doc "Emits a region using runtime tuple updates that remain valid at early boundaries."
  @spec lower_region(Function.t(), plan(), map()) :: {:ok, Template.t()} | :not_eligible
  def lower_region(%Function{} = function, plan, levels) when is_map(plan) and is_map(levels),
    do: lower(function, plan, levels, :runtime)

  defp lower(function, plan, levels, tuple_mode) do
    if eligible?(function, plan, levels) do
      {:ok,
       %Template{
         forms: [
           {:attribute, @line, :module, Template.placeholder_module()},
           {:attribute, @line, :export, [run: 3]},
           run_form(),
           block_form(plan, levels, tuple_mode),
           {:eof, @line}
         ]
       }}
    else
      :not_eligible
    end
  end

  defp eligible?(function, plan, levels) do
    bounded_shape?(function, plan, levels) and eligible_constants?(function.constants) and
      checked_locals_initialized?(function, plan)
  end

  defp bounded_shape?(function, plan, levels) do
    function.stack_size <= @max_stack_depth and function.arg_count <= 8 and
      function.var_count <= 8 and map_size(plan) <= @max_scalar_blocks and
      scalar_operation_count(plan) <= @max_scalar_operations and
      Enum.all?(plan, fn {_pc, {operations, _reason}} -> length(operations) <= 32 end) and
      Enum.all?(levels, fn {_pc, {depth, _catch}} -> depth <= @max_stack_depth end)
  end

  defp eligible_constants?(constants), do: not captured_frame_slots?(constants)

  defp checked_locals_initialized?(function, plan) do
    count = max(function.arg_count + function.var_count, 1)
    initialized = MapSet.new(0..(count - 1))
    walk_initialization(plan, %{0 => initialized}, [0])
  end

  defp walk_initialization(_plan, _entries, []), do: true

  defp walk_initialization(plan, entries, [pc | queue]) do
    case Map.fetch(plan, pc) do
      :error ->
        walk_initialization(plan, entries, queue)

      {:ok, {operations, reason}} ->
        initialized = Map.fetch!(entries, pc)

        case apply_initialization(operations, initialized) do
          :unsafe ->
            false

          initialized ->
            successors = initialization_successors(pc, operations, reason)
            {entries, queue} = merge_initialization(successors, initialized, entries, queue)
            walk_initialization(plan, entries, queue)
        end
    end
  end

  defp apply_initialization([], initialized), do: initialized

  defp apply_initialization([{:local, :get_loc_check, [index]} | operations], initialized) do
    if MapSet.member?(initialized, index),
      do: apply_initialization(operations, initialized),
      else: :unsafe
  end

  defp apply_initialization(
         [{:local, :set_loc_uninitialized, [index]} | operations],
         initialized
       ),
       do: apply_initialization(operations, MapSet.delete(initialized, index))

  defp apply_initialization([{:local, name, [index]} | operations], initialized)
       when name in [:put_loc, :set_loc, :put_loc_check, :put_loc_check_init],
       do: apply_initialization(operations, MapSet.put(initialized, index))

  defp apply_initialization([_operation | operations], initialized),
    do: apply_initialization(operations, initialized)

  defp initialization_successors(pc, operations, reason) do
    case List.last(operations) do
      {:branch, name, [target]} when name in [:if_false, :if_false8, :if_true, :if_true8] ->
        [target, pc + length(operations)]

      {:branch, name, [target]} when name in [:goto, :goto8, :goto16] ->
        [target]

      _operation when reason == :continue ->
        [pc + length(operations)]

      _operation ->
        []
    end
  end

  defp merge_initialization(successors, initialized, entries, queue) do
    Enum.reduce(successors, {entries, queue}, fn successor, accumulator ->
      merge_initialization_successor(successor, initialized, accumulator)
    end)
  end

  defp merge_initialization_successor(successor, initialized, {entries, queue}) do
    case Map.fetch(entries, successor) do
      :error ->
        {Map.put(entries, successor, initialized), [successor | queue]}

      {:ok, existing} ->
        merged = MapSet.intersection(existing, initialized)

        if merged == existing,
          do: {entries, queue},
          else: {Map.put(entries, successor, merged), [successor | queue]}
    end
  end

  defp scalar_operation_count(plan),
    do:
      Enum.reduce(plan, 0, fn {_pc, {operations, _reason}}, count ->
        count + length(operations)
      end)

  defp captured_frame_slots?(constants) do
    Enum.any?(constants, fn
      %Function{closure_vars: closure_vars} ->
        Enum.any?(closure_vars, &(Map.get(&1, :closure_type) in [0, 1]))

      _constant ->
        false
    end)
  end

  defp run_form do
    lease = variable(:Lease)
    frame = variable(:Frame)
    execution = variable(:Execution)
    pc = variable(:PC)
    args = variable(:Args)
    locals = variable(:Locals)
    stack = variable(:Stack)

    state = remote_call(Runtime, :frame_state, [frame])

    body =
      case_expression(state, [
        clause(
          [tuple([pc, args, locals, stack])],
          [local_call(:block, [pc, lease, frame, args, locals, stack, execution])]
        )
      ])

    function(:run, 3, [clause([lease, frame, execution], [body])])
  end

  defp block_form(plan, levels, tuple_mode) do
    clauses =
      plan
      |> Enum.sort_by(fn {pc, _block} -> pc end)
      |> Enum.map(fn {pc, block} -> block_clause(pc, block, levels, tuple_mode) end)

    fallback =
      clause(
        [
          variable(:_PC),
          variable(:Lease),
          variable(:Frame),
          variable(:Args),
          variable(:Locals),
          variable(:Stack),
          variable(:Execution)
        ],
        [deopt_from_arguments(:unsupported_semantics, variable(:_PC), variable(:Stack))]
      )

    function(:block, 7, clauses ++ [fallback])
  end

  defp block_clause(pc, {[], reason}, levels, _tuple_mode) do
    depth = stack_depth!(levels, pc)

    clause(
      block_arguments(pc, depth),
      [deopt_from_arguments(reason, integer(pc), stack_expression(depth))]
    )
  end

  defp block_clause(pc, {[{family, name, _operands}] = operations, reason}, levels, tuple_mode)
       when family == :object or (family == :global and name == :get_var) do
    depth = stack_depth!(levels, pc)

    state = %{
      pc: pc,
      lease: variable(:Lease),
      frame: variable(:Frame),
      args: variable(:Args),
      locals: variable(:Locals),
      stack: stack_values(depth),
      execution: variable(:Execution),
      tuple_mode: tuple_mode
    }

    clause(block_arguments(pc, depth), [lower_operations(operations, reason, state)])
  end

  defp block_clause(pc, {operations, reason}, levels, tuple_mode) do
    depth = stack_depth!(levels, pc)
    lease = variable(:Lease)
    frame = variable(:Frame)
    args = variable(:Args)
    locals = variable(:Locals)
    execution = variable(:Execution)
    charged_execution = variable(:ChargedExecution)
    action = variable(:Action)

    state = %{
      pc: pc,
      lease: lease,
      frame: frame,
      args: args,
      locals: locals,
      stack: stack_values(depth),
      execution: charged_execution,
      tuple_mode: tuple_mode
    }

    lowered = lower_operations(operations, reason, state)

    compact = tuple([frame, integer(pc), args, locals, stack_expression(depth)])

    charge =
      remote_call(Runtime, :charge_state, [lease, compact, execution, integer(length(operations))])

    body =
      case_expression(charge, [
        clause([tuple([atom(:ok), charged_execution])], [lowered]),
        clause([action], [action])
      ])

    clause(block_arguments(pc, depth), [body])
  end

  defp block_arguments(pc, depth) do
    [
      integer(pc),
      variable(:Lease),
      variable(:Frame),
      variable(:Args),
      variable(:Locals),
      stack_expression(depth),
      variable(:Execution)
    ]
  end

  defp lower_operations([], reason, state), do: boundary_expression(reason, state)

  defp lower_operations([{:global, name, operands} | operations], reason, state) do
    lower_global(name, operands, operations, reason, state)
  end

  defp lower_operations([{:object, name, operands} | operations], reason, state) do
    lower_property(name, operands, operations, reason, state)
  end

  defp lower_operations([{:invocation, name, operands}], _reason, state),
    do: lower_invocation(name, operands, state)

  defp lower_operations([operation | operations], reason, state) do
    case lower_operation(operation, state) do
      {:next, state} -> lower_operations(operations, reason, state)
      {:terminal, expression} -> expression
    end
  end

  defp lower_global(name, _operands, operations, reason, state)
       when name in [:check_define_var, :define_var] do
    lower_operations(operations, reason, %{state | pc: state.pc + 1})
  end

  defp lower_global(:push_atom_value, [atom_operand], operations, reason, state) do
    value = remote_call(Runtime, :resolve_atom, [literal(atom_operand), state.execution])
    next_state = %{state | pc: state.pc + 1, stack: [value | state.stack]}
    lower_operations(operations, reason, next_state)
  end

  defp lower_global(name, [atom_operand], operations, reason, state)
       when name in [:get_var, :get_var_undef] do
    value = variable(elem(@global_variables, rem(state.pc, 256)))
    get = remote_call(Runtime, :global_get, [atom(name), literal(atom_operand), state.execution])
    next_state = %{state | pc: state.pc + 1, stack: [value | state.stack]}

    success =
      if name == :get_var do
        charge_preflight(state, fn execution ->
          lower_operations(operations, reason, %{next_state | execution: execution})
        end)
      else
        lower_operations(operations, reason, next_state)
      end

    case_expression(get, [
      clause([tuple([atom(:ok), value])], [success]),
      clause([atom(:deopt)], [deopt_call(:unsupported_semantics, integer(state.pc), state)])
    ])
  end

  defp lower_global(name, [atom_operand | _flags], operations, reason, state)
       when name in [:put_var, :put_var_init, :define_func] do
    [value | stack] = state.stack
    execution = variable(elem(@execution_variables, rem(state.pc, 256)))
    put = remote_call(Runtime, :global_put, [literal(atom_operand), value, state.execution])
    next_state = %{state | pc: state.pc + 1, stack: stack, execution: execution}

    case_expression(put, [clause([execution], [lower_operations(operations, reason, next_state)])])
  end

  defp lower_invocation(:call, [argument_count], state) do
    {arguments, [callable | stack]} = Enum.split(state.stack, argument_count)
    arguments = arguments |> Enum.reverse() |> list()
    state = %{state | pc: state.pc + 1, stack: stack}
    invoke_call(callable, arguments, literal(:undefined), state)
  end

  defp lower_invocation(:call_method, [argument_count], state) do
    {arguments, [callable, this | stack]} = Enum.split(state.stack, argument_count)
    arguments = arguments |> Enum.reverse() |> list()
    state = %{state | pc: state.pc + 1, stack: stack}
    invoke_call(callable, arguments, this, state)
  end

  defp invoke_call(callable, arguments, this, state) do
    compact = tuple([state.frame, integer(state.pc), state.args, state.locals, list(state.stack)])

    remote_call(Runtime, :invoke_state, [
      callable,
      arguments,
      this,
      compact,
      state.execution
    ])
  end

  defp lower_property(name, operands, operations, reason, state) do
    {object, key, result_stack} = property_operands(name, operands, state)
    property_value = variable(elem(@property_variables, rem(state.pc, 256)))
    get = remote_call(Runtime, :property_get, [object, key, state.execution])
    next_state = %{state | pc: state.pc + 1, stack: [property_value | result_stack]}

    success =
      charge_preflight(state, fn execution ->
        lower_operations(operations, reason, %{next_state | execution: execution})
      end)

    case_expression(get, [
      clause([tuple([atom(:ok), property_value])], [success]),
      clause([atom(:deopt)], [deopt_call(:unsupported_semantics, integer(state.pc), state)])
    ])
  end

  defp charge_preflight(state, continuation) do
    execution = variable(elem(@execution_variables, rem(state.pc, 256)))
    action = variable(:Action)
    compact = tuple([state.frame, integer(state.pc), state.args, state.locals, list(state.stack)])

    charge =
      remote_call(Runtime, :charge_state, [state.lease, compact, state.execution, integer(1)])

    case_expression(charge, [
      clause([tuple([atom(:ok), execution])], [continuation.(execution)]),
      clause([action], [action])
    ])
  end

  defp property_operands(:get_field, [atom_operand], %{stack: [object | stack]} = state) do
    key = remote_call(Runtime, :resolve_atom, [literal(atom_operand), state.execution])
    {object, key, stack}
  end

  defp property_operands(:get_field2, [atom_operand], %{stack: [object | stack]} = state) do
    key = remote_call(Runtime, :resolve_atom, [literal(atom_operand), state.execution])
    {object, key, [object | stack]}
  end

  defp property_operands(:get_array_el, [], %{stack: [key, object | stack]}),
    do: {object, key, stack}

  defp property_operands(:get_length, [], %{stack: [object | stack]}),
    do: {object, literal("length"), stack}

  defp lower_operation({:stack, name, operands}, state),
    do: {:next, lower_stack(name, operands, state)}

  defp lower_operation({:local, name, operands}, state),
    do: {:next, lower_local(name, operands, state)}

  defp lower_operation({:value, name, []}, %{stack: [right, left | stack]} = state)
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
    value = binary_expression(name, left, right, state.pc)
    {:next, %{state | pc: state.pc + 1, stack: [value | stack]}}
  end

  defp lower_operation({:value, name, []}, %{stack: [value | stack]} = state)
       when name in [:post_inc, :post_dec] do
    operation = if name == :post_inc, do: :inc, else: :dec
    updated = unary_expression(operation, value, state.pc)
    {:next, %{state | pc: state.pc + 1, stack: [updated, value | stack]}}
  end

  defp lower_operation({:value, name, []}, %{stack: [value | stack]} = state) do
    value = unary_expression(name, value, state.pc)
    {:next, %{state | pc: state.pc + 1, stack: [value | stack]}}
  end

  defp lower_operation(
         {:branch, name, [target]},
         %{stack: [condition | stack]} = state
       )
       when name in [:if_false, :if_false8, :if_true, :if_true8] do
    state = %{state | stack: stack}
    fallthrough = block_call(%{state | pc: state.pc + 1})
    target = block_call(%{state | pc: target})
    truthy = remote_call(Runtime, :truthy?, [condition])

    {false_body, true_body} =
      if name in [:if_false, :if_false8], do: {target, fallthrough}, else: {fallthrough, target}

    {:terminal,
     case_expression(truthy, [
       clause([atom(false)], [false_body]),
       clause([atom(true)], [true_body])
     ])}
  end

  defp lower_operation({:branch, name, [target]}, state)
       when name in [:goto, :goto8, :goto16],
       do: {:terminal, block_call(%{state | pc: target})}

  defp lower_stack(name, operands, state) when name in [:push_i32, :push_i8, :push_i16] do
    [value] = operands
    %{state | pc: state.pc + 1, stack: [integer(value) | state.stack]}
  end

  defp lower_stack(:push_bigint_i32, [value], state),
    do: %{state | pc: state.pc + 1, stack: [literal({:bigint, value}) | state.stack]}

  defp lower_stack(:undefined, [], state), do: push_literal(state, :undefined)
  defp lower_stack(:null, [], state), do: push_literal(state, nil)
  defp lower_stack(:push_false, [], state), do: push_literal(state, false)
  defp lower_stack(:push_true, [], state), do: push_literal(state, true)

  defp lower_stack(:push_this, [], state),
    do: push_expression(state, remote_call(Runtime, :frame_this, [state.frame]))

  defp lower_stack(name, [index], state) when name in [:push_const, :push_const8],
    do:
      push_expression(state, remote_call(Runtime, :frame_constant, [state.frame, integer(index)]))

  defp lower_stack(:drop, [], %{stack: [_value | stack]} = state),
    do: advance_stack(state, stack)

  defp lower_stack(:dup, [], %{stack: [value | _]} = state),
    do: advance_stack(state, [value | state.stack])

  defp lower_stack(:dup1, [], %{stack: [a, b | stack]} = state),
    do: advance_stack(state, [a, b, b | stack])

  defp lower_stack(:dup2, [], %{stack: [a, b | stack]} = state),
    do: advance_stack(state, [a, b, a, b | stack])

  defp lower_stack(:dup3, [], %{stack: [a, b, c | stack]} = state),
    do: advance_stack(state, [a, b, c, a, b, c | stack])

  defp lower_stack(name, [], %{stack: [a, _b | stack]} = state)
       when name in [:nip, :nip_catch],
       do: advance_stack(state, [a | stack])

  defp lower_stack(:nip1, [], %{stack: [a, b, _c | stack]} = state),
    do: advance_stack(state, [a, b | stack])

  defp lower_stack(:swap, [], %{stack: [a, b | stack]} = state),
    do: advance_stack(state, [b, a | stack])

  defp lower_stack(:swap2, [], %{stack: [a, b, c, d | stack]} = state),
    do: advance_stack(state, [c, d, a, b | stack])

  defp lower_stack(:perm3, [], %{stack: [a, b, c | stack]} = state),
    do: advance_stack(state, [a, c, b | stack])

  defp lower_stack(:perm4, [], %{stack: [a, b, c, d | stack]} = state),
    do: advance_stack(state, [a, c, d, b | stack])

  defp lower_stack(:perm5, [], %{stack: [a, b, c, d, e | stack]} = state),
    do: advance_stack(state, [a, c, d, e, b | stack])

  defp lower_stack(:rot3l, [], %{stack: [a, b, c | stack]} = state),
    do: advance_stack(state, [c, a, b | stack])

  defp lower_stack(:rot3r, [], %{stack: [a, b, c | stack]} = state),
    do: advance_stack(state, [b, c, a | stack])

  defp lower_stack(:rot4l, [], %{stack: [a, b, c, d | stack]} = state),
    do: advance_stack(state, [d, a, b, c | stack])

  defp lower_stack(:rot5l, [], %{stack: [a, b, c, d, e | stack]} = state),
    do: advance_stack(state, [e, a, b, c, d | stack])

  defp lower_stack(:insert2, [], %{stack: [a, b | stack]} = state),
    do: advance_stack(state, [a, b, a | stack])

  defp lower_stack(:insert3, [], %{stack: [a, b, c | stack]} = state),
    do: advance_stack(state, [a, b, c, a | stack])

  defp lower_local(:get_arg, [index], state),
    do: push_expression(state, tuple_element(state.args, index))

  defp lower_local(:put_arg, [index], %{stack: [value | stack]} = state),
    do: %{
      state
      | pc: state.pc + 1,
        args: tuple_put(state, state.args, index, value),
        stack: stack
    }

  defp lower_local(:set_arg, [index], %{stack: [value | _]} = state),
    do: %{state | pc: state.pc + 1, args: tuple_put(state, state.args, index, value)}

  defp lower_local(name, [index], state) when name in [:get_loc, :get_loc_check],
    do: push_expression(state, tuple_element(state.locals, index))

  defp lower_local(:get_loc0_loc1, [first, second], state) do
    first = tuple_element(state.locals, first)
    second = tuple_element(state.locals, second)
    %{state | pc: state.pc + 1, stack: [first, second | state.stack]}
  end

  defp lower_local(name, [index], state) when name in [:inc_loc, :dec_loc] do
    operation = if name == :inc_loc, do: :inc, else: :dec
    current = tuple_element(state.locals, index)
    value = unary_expression(operation, current, state.pc)
    %{state | pc: state.pc + 1, locals: tuple_put(state, state.locals, index, value)}
  end

  defp lower_local(:add_loc, [index], %{stack: [value | stack]} = state) do
    current = tuple_element(state.locals, index)
    value = binary_expression(:add, current, value, state.pc)

    %{
      state
      | pc: state.pc + 1,
        locals: tuple_put(state, state.locals, index, value),
        stack: stack
    }
  end

  defp lower_local(name, [index], %{stack: [value | stack]} = state)
       when name in [:put_loc, :put_loc_check_init, :put_loc_check],
       do: %{
         state
         | pc: state.pc + 1,
           locals: tuple_put(state, state.locals, index, value),
           stack: stack
       }

  defp lower_local(:set_loc, [index], %{stack: [value | _]} = state),
    do: %{state | pc: state.pc + 1, locals: tuple_put(state, state.locals, index, value)}

  defp lower_local(:set_loc_uninitialized, [index], state),
    do: %{
      state
      | pc: state.pc + 1,
        locals: tuple_put(state, state.locals, index, atom(:uninitialized))
    }

  defp boundary_expression(:continue, state), do: block_call(state)
  defp boundary_expression(reason, state), do: deopt_call(reason, integer(state.pc), state)

  defp block_call(state) do
    local_call(:block, [
      integer(state.pc),
      state.lease,
      state.frame,
      state.args,
      state.locals,
      list(state.stack),
      state.execution
    ])
  end

  defp deopt_call(reason, pc, state) do
    compact = tuple([state.frame, pc, state.args, state.locals, list(state.stack)])
    remote_call(Runtime, :deopt_state, [atom(reason), state.lease, compact, state.execution])
  end

  defp deopt_from_arguments(reason, pc, stack) do
    compact = tuple([variable(:Frame), pc, variable(:Args), variable(:Locals), stack])

    remote_call(Runtime, :deopt_state, [
      atom(reason),
      variable(:Lease),
      compact,
      variable(:Execution)
    ])
  end

  defp stack_depth!(levels, pc) do
    {depth, _catch} = Map.fetch!(levels, pc)
    depth
  end

  defp stack_values(0), do: []

  defp stack_values(depth),
    do: for(index <- 0..(depth - 1), do: variable(elem(@stack_variables, index)))

  defp stack_expression(depth), do: list(stack_values(depth))

  defp push_literal(state, value), do: push_expression(state, literal(value))

  defp push_expression(state, expression),
    do: %{state | pc: state.pc + 1, stack: [expression | state.stack]}

  defp advance_stack(state, stack), do: %{state | pc: state.pc + 1, stack: stack}

  defp binary_expression(:mod, {:integer, _, _} = left, {:integer, _, right} = right_expr, _pc)
       when right != 0,
       do: remote_call(:erlang, :rem, [left, right_expr])

  defp binary_expression(name, left, right, pc)
       when name in [:add, :sub, :mul, :lt, :lte, :gt, :gte, :eq, :neq, :strict_eq, :strict_neq] do
    operator = binary_operator(name)

    if numeric_expression?(left) and numeric_expression?(right) do
      operation(operator, left, right)
    else
      left_var = variable(elem(@left_variables, rem(pc, 256)))
      right_var = variable(elem(@right_variables, rem(pc, 256)))
      guards = [[guard_call(:is_number, [left_var]), guard_call(:is_number, [right_var])]]

      anonymous_call(
        [
          guarded_clause([left_var, right_var], guards, [operation(operator, left_var, right_var)]),
          clause(
            [left_var, right_var],
            [remote_call(Runtime, :binary, [atom(name), left_var, right_var])]
          )
        ],
        [left, right]
      )
    end
  end

  defp binary_expression(:mod = name, left, right, pc) do
    left_var = variable(elem(@left_variables, rem(pc, 256)))
    right_var = variable(elem(@right_variables, rem(pc, 256)))

    guards = [
      [
        guard_call(:is_integer, [left_var]),
        guard_call(:is_integer, [right_var]),
        operation(:"=/=", right_var, integer(0))
      ]
    ]

    anonymous_call(
      [
        guarded_clause(
          [left_var, right_var],
          guards,
          [remote_call(:erlang, :rem, [left_var, right_var])]
        ),
        clause(
          [left_var, right_var],
          [remote_call(Runtime, :binary, [atom(name), left_var, right_var])]
        )
      ],
      [left, right]
    )
  end

  defp binary_expression(name, left, right, _pc),
    do: remote_call(Runtime, :binary, [atom(name), left, right])

  defp unary_expression(name, {type, _, _} = value, _pc)
       when type in [:integer, :float] and name in [:neg, :plus, :inc, :dec],
       do: unary_numeric_expression(name, value)

  defp unary_expression(name, value, pc) when name in [:neg, :plus, :inc, :dec] do
    value_var = variable(elem(@value_variables, rem(pc, 256)))
    guards = [[guard_call(:is_number, [value_var])]]

    anonymous_call(
      [
        guarded_clause([value_var], guards, [unary_numeric_expression(name, value_var)]),
        clause([value_var], [remote_call(Runtime, :unary, [atom(name), value_var])])
      ],
      [value]
    )
  end

  defp unary_expression(name, value, _pc),
    do: remote_call(Runtime, :unary, [atom(name), value])

  defp numeric_expression?({type, _, _}) when type in [:integer, :float], do: true

  defp numeric_expression?({:op, _, operator, left, right})
       when operator in [:+, :-, :*],
       do: numeric_expression?(left) and numeric_expression?(right)

  defp numeric_expression?(_expression), do: false

  defp binary_operator(:add), do: :+
  defp binary_operator(:sub), do: :-
  defp binary_operator(:mul), do: :*
  defp binary_operator(:lt), do: :<
  defp binary_operator(:lte), do: :"=<"
  defp binary_operator(:gt), do: :>
  defp binary_operator(:gte), do: :>=
  defp binary_operator(name) when name in [:eq, :strict_eq], do: :==
  defp binary_operator(name) when name in [:neq, :strict_neq], do: :"/="

  defp unary_numeric_expression(:neg, value), do: operation(:-, value)
  defp unary_numeric_expression(:plus, value), do: value
  defp unary_numeric_expression(:inc, value), do: operation(:+, value, integer(1))
  defp unary_numeric_expression(:dec, value), do: operation(:-, value, integer(1))

  defp tuple_element(tuple, index),
    do: remote_call(:erlang, :element, [integer(index + 1), tuple])

  defp tuple_put(%{tuple_mode: :beam}, tuple, index, value),
    do: remote_call(:erlang, :setelement, [integer(index + 1), tuple, value])

  defp tuple_put(%{tuple_mode: :runtime}, tuple, index, value),
    do: remote_call(Runtime, :tuple_put, [tuple, integer(index), value])

  defp function(name, arity, clauses), do: {:function, @line, name, arity, clauses}
  defp clause(arguments, body), do: {:clause, @line, arguments, [], body}
  defp guarded_clause(arguments, guards, body), do: {:clause, @line, arguments, guards, body}
  defp variable(name), do: {:var, @line, name}
  defp atom(value), do: {:atom, @line, value}
  defp integer(value), do: {:integer, @line, value}
  defp literal(value), do: :erl_parse.abstract(value)
  defp tuple(values), do: {:tuple, @line, values}
  defp list(values), do: Enum.reduce(Enum.reverse(values), {nil, @line}, &{:cons, @line, &1, &2})
  defp local_call(name, arguments), do: {:call, @line, atom(name), arguments}
  defp guard_call(name, arguments), do: {:call, @line, atom(name), arguments}
  defp operation(name, value), do: {:op, @line, name, value}
  defp operation(name, left, right), do: {:op, @line, name, left, right}

  defp remote_call(module, name, arguments),
    do: {:call, @line, {:remote, @line, atom(module), atom(name)}, arguments}

  defp case_expression(expression, clauses), do: {:case, @line, expression, clauses}

  defp anonymous_call(clauses, arguments),
    do: {:call, @line, {:fun, @line, {:clauses, clauses}}, arguments}
end
