defmodule QuickBEAM.BeamVM.Compiler.Lowering do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.{Analysis, Lowering.Ops, Lowering.State}

  @line 1

  def lower(fun, instructions) do
    entries = Analysis.block_entries(instructions)
    slot_count = fun.arg_count + fun.var_count
    constants = fun.constants

    with {:ok, stack_depths} <- Analysis.infer_block_stack_depths(instructions, entries),
         {:ok, {entry_types, return_type}} <-
           Analysis.infer_block_entry_types(fun, instructions, entries, stack_depths) do
      inline_targets = Analysis.inlineable_entries(instructions, entries)

      blocks =
        for start <- entries,
            Map.has_key?(stack_depths, start),
            not MapSet.member?(inline_targets, start),
            into: [] do
          {start,
           block_form(
             fun,
             start,
             fun.arg_count,
             slot_count,
             instructions,
             entries,
             Map.fetch!(stack_depths, start),
             stack_depths,
             constants,
             inline_targets,
             Map.get(entry_types, start),
             return_type
           )}
        end

      case Enum.find(blocks, fn {_start, form} -> match?({:error, _}, form) end) do
        nil -> {:ok, {slot_count, Enum.map(blocks, &elem(&1, 1))}}
        {_start, error} -> error
      end
    end
  end

  defp block_form(
         fun,
         start,
         arg_count,
         slot_count,
         instructions,
         entries,
         stack_depth,
         stack_depths,
         constants,
         inline_targets,
         entry_type_state,
         return_type
       ) do
    state_opts =
      [
        locals: fun.locals,
        atoms: Process.get({:qb_fn_atoms, fun.byte_code}),
        arg_count: arg_count,
        return_type: return_type
      ] ++
        if entry_type_state do
          [slot_types: entry_type_state.slot_types, stack_types: entry_type_state.stack_types]
        else
          []
        end

    state = State.new(slot_count, stack_depth, state_opts)

    next_entry = Analysis.next_entry(entries, start)

    args =
      State.slot_vars(slot_count) ++
        State.stack_vars(stack_depth) ++ State.capture_vars(slot_count)

    with {:ok, body} <-
           lower_block(
             instructions,
             start,
             next_entry,
             arg_count,
             state,
             stack_depths,
             constants,
             entries,
             inline_targets
           ) do
      {:function, @line, State.block_name(start), slot_count + stack_depth + slot_count,
       [{:clause, @line, args, [], body}]}
    end
  end

  defp lower_block(
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         _stack_depths,
         _constants,
         _entries,
         _inline_targets
       )
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx, next_entry, arg_count, state.body}}
  end

  defp lower_block(
         instructions,
         idx,
         idx,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    if MapSet.member?(inline_targets, idx) do
      lower_block(
        instructions,
        idx,
        Analysis.next_entry(entries, idx),
        arg_count,
        state,
        stack_depths,
        constants,
        entries,
        inline_targets
      )
    else
      with {:ok, call} <- State.block_jump_call(state, idx, stack_depths) do
        {:ok, state.body ++ [call]}
      end
    end
  end

  defp lower_block(
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    instruction = Enum.at(instructions, idx)

    case instruction do
      {op, [target]} ->
        case Analysis.opcode_name(op) do
          {:ok, :catch} ->
            lower_catch_suffix(
              instructions,
              idx,
              next_entry,
              arg_count,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              target
            )

          {:ok, :gosub} ->
            lower_gosub_suffix(
              instructions,
              idx,
              next_entry,
              arg_count,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              target
            )

          _ ->
            lower_instruction(
              instruction,
              instructions,
              idx,
              next_entry,
              arg_count,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets
            )
        end

      _ ->
        lower_instruction(
          instruction,
          instructions,
          idx,
          next_entry,
          arg_count,
          state,
          stack_depths,
          constants,
          entries,
          inline_targets
        )
    end
  end

  defp lower_instruction(
         {op, [target]} = instruction,
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    case Analysis.opcode_name(op) do
      {:ok, :if_false} ->
        lower_branch_instruction(
          instructions,
          idx,
          next_entry,
          arg_count,
          state,
          stack_depths,
          constants,
          entries,
          inline_targets,
          target,
          false
        )

      {:ok, :if_false8} ->
        lower_branch_instruction(
          instructions,
          idx,
          next_entry,
          arg_count,
          state,
          stack_depths,
          constants,
          entries,
          inline_targets,
          target,
          false
        )

      {:ok, :if_true} ->
        lower_branch_instruction(
          instructions,
          idx,
          next_entry,
          arg_count,
          state,
          stack_depths,
          constants,
          entries,
          inline_targets,
          target,
          true
        )

      {:ok, :if_true8} ->
        lower_branch_instruction(
          instructions,
          idx,
          next_entry,
          arg_count,
          state,
          stack_depths,
          constants,
          entries,
          inline_targets,
          target,
          true
        )

      _ ->
        lower_non_branch_instruction(
          instruction,
          instructions,
          idx,
          next_entry,
          arg_count,
          state,
          stack_depths,
          constants,
          entries,
          inline_targets
        )
    end
  end

  defp lower_instruction(
         instruction,
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    lower_non_branch_instruction(
      instruction,
      instructions,
      idx,
      next_entry,
      arg_count,
      state,
      stack_depths,
      constants,
      entries,
      inline_targets
    )
  end

  defp lower_non_branch_instruction(
         instruction,
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    case Ops.lower_instruction(
           instruction,
           idx,
           next_entry,
           arg_count,
           state,
           stack_depths,
           constants,
           entries,
           inline_targets
         ) do
      {:ok, next_state} ->
        lower_block(
          instructions,
          idx + 1,
          next_entry,
          arg_count,
          next_state,
          stack_depths,
          constants,
          entries,
          inline_targets
        )

      {:inline_goto, target, next_state} ->
        lower_block(
          instructions,
          target,
          Analysis.next_entry(entries, target),
          arg_count,
          next_state,
          stack_depths,
          constants,
          entries,
          inline_targets
        )

      {:done, body} ->
        {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  defp lower_branch_instruction(
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         target,
         sense
       ) do
    if MapSet.member?(inline_targets, target) or MapSet.member?(inline_targets, next_entry) do
      with {:ok, cond_expr, cond_type, state} <- State.pop_typed(state),
           {:ok, target_body} <-
             lower_branch_target_body(
               instructions,
               target,
               arg_count,
               state,
               stack_depths,
               constants,
               entries,
               inline_targets
             ),
           {:ok, next_body} <-
             lower_branch_target_body(
               instructions,
               next_entry,
               arg_count,
               state,
               stack_depths,
               constants,
               entries,
               inline_targets
             ) do
        truthy = State.branch_condition(cond_expr, cond_type)
        false_body = if(sense, do: next_body, else: target_body)
        true_body = if(sense, do: target_body, else: next_body)
        {:ok, state.body ++ [State.branch_case(truthy, false_body, true_body)]}
      end
    else
      lower_non_branch_instruction(
        {if(sense,
           do: QuickBEAM.BeamVM.Opcodes.num(:if_true),
           else: QuickBEAM.BeamVM.Opcodes.num(:if_false)
         ), [target]},
        instructions,
        idx,
        next_entry,
        arg_count,
        state,
        stack_depths,
        constants,
        entries,
        inline_targets
      )
    end
  end

  defp lower_branch_target_body(
         _instructions,
         nil,
         _arg_count,
         _state,
         _stack_depths,
         _constants,
         _entries,
         _inline_targets
       ),
       do: {:error, :missing_branch_fallthrough}

  defp lower_branch_target_body(
         instructions,
         target,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    if MapSet.member?(inline_targets, target) do
      lower_block(
        instructions,
        target,
        Analysis.next_entry(entries, target),
        arg_count,
        %{state | body: []},
        stack_depths,
        constants,
        entries,
        inline_targets
      )
    else
      with {:ok, call} <- State.block_jump_call(state, target, stack_depths) do
        {:ok, [call]}
      end
    end
  end

  defp lower_catch_suffix(
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         target
       ) do
    with :ok <- ensure_catch_region_supported(instructions, idx, target),
         {saved_stack, state} <- freeze_stack(state),
         {:ok, handler_call} <-
           State.block_jump_call_values(
             target,
             stack_depths,
             State.current_slots(state),
             [State.var("Caught#{idx}") | saved_stack],
             State.current_capture_cells(state)
           ),
         {:ok, try_body} <-
           lower_block(
             instructions,
             idx + 1,
             next_entry,
             arg_count,
             %{
               state
               | body: [],
                 stack: [State.literal(target) | saved_stack],
                 stack_types: [:integer | state.stack_types]
             },
             stack_depths,
             constants,
             entries,
             inline_targets
           ) do
      {:ok,
       state.body ++ [State.try_catch_expr(try_body, State.var("Caught#{idx}"), [handler_call])]}
    end
  end

  defp lower_gosub_suffix(
         instructions,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         target
       ) do
    with {:ok, inlined_state} <- lower_finally_inline(instructions, target, state) do
      lower_block(
        instructions,
        idx + 1,
        next_entry,
        arg_count,
        inlined_state,
        stack_depths,
        constants,
        entries,
        inline_targets
      )
    end
  end

  defp lower_finally_inline(instructions, idx, _state) when idx >= length(instructions) do
    {:error, {:missing_ret, idx}}
  end

  defp lower_finally_inline(instructions, idx, state) do
    instruction = Enum.at(instructions, idx)

    case instruction do
      {op, []} ->
        case Analysis.opcode_name(op) do
          {:ok, :ret} ->
            {:ok, state}

          {:ok, name} when name in [:catch, :gosub, :goto, :goto8, :goto16] ->
            {:error, {:unsupported_finally_opcode, name, idx}}

          _ ->
            lower_finally_instruction(instructions, instruction, idx, state)
        end

      {op, _args} ->
        case Analysis.opcode_name(op) do
          {:ok, :gosub} ->
            {:error, {:unsupported_finally_opcode, :gosub, idx}}

          {:ok, :catch} ->
            {:error, {:unsupported_finally_opcode, :catch, idx}}

          {:ok, name}
          when name in [:if_false, :if_false8, :if_true, :if_true8, :goto, :goto8, :goto16] ->
            {:error, {:unsupported_finally_opcode, name, idx}}

          _ ->
            lower_finally_instruction(instructions, instruction, idx, state)
        end
    end
  end

  defp lower_finally_instruction(instructions, instruction, idx, state) do
    case Ops.lower_instruction(instruction, idx, nil, 0, state, %{}, [], [], MapSet.new()) do
      {:ok, next_state} ->
        lower_finally_inline(instructions, idx + 1, next_state)

      {:done, body} ->
        {:ok, %{state | body: body, stack: state.stack, stack_types: state.stack_types}}

      {:error, _} = error ->
        error
    end
  end

  defp freeze_stack(%{stack: []} = state), do: {[], state}

  defp freeze_stack(state) do
    state =
      Enum.reduce(0..(length(state.stack) - 1), state, fn idx, state ->
        {:ok, state, _bound} = State.bind_stack_entry(state, idx)
        state
      end)

    {state.stack, state}
  end

  defp ensure_catch_region_supported(_instructions, _catch_idx, _target), do: :ok
end
