defmodule QuickBEAM.BeamVM.Compiler.Lowering do
  @moduledoc false

  alias QuickBEAM.BeamVM.Compiler.{Analysis, Lowering.Ops, Lowering.State}

  @line 1

  def lower(fun, instructions) do
    entries = Analysis.block_entries(instructions)
    slot_count = fun.arg_count + fun.var_count

    with {:ok, stack_depths} <- Analysis.infer_block_stack_depths(instructions, entries) do
      blocks =
        for start <- entries, Map.has_key?(stack_depths, start), into: [] do
          {start,
           block_form(
             start,
             fun.arg_count,
             slot_count,
             instructions,
             entries,
             Map.fetch!(stack_depths, start),
             stack_depths
           )}
        end

      case Enum.find(blocks, fn {_start, form} -> match?({:error, _}, form) end) do
        nil -> {:ok, {slot_count, Enum.map(blocks, &elem(&1, 1))}}
        {_start, error} -> error
      end
    end
  end

  defp block_form(start, arg_count, slot_count, instructions, entries, stack_depth, stack_depths) do
    state = State.new(slot_count, stack_depth)
    next_entry = Analysis.next_entry(entries, start)
    args = State.slot_vars(slot_count) ++ State.stack_vars(stack_depth)

    with {:ok, body} <-
           lower_block(instructions, start, next_entry, arg_count, state, stack_depths) do
      {:function, @line, State.block_name(start), slot_count + stack_depth,
       [{:clause, @line, args, [], body}]}
    end
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state, _stack_depths)
       when idx >= length(instructions) do
    {:error, {:missing_terminator, idx, next_entry, arg_count, state.body}}
  end

  defp lower_block(_instructions, idx, idx, _arg_count, state, stack_depths) do
    with {:ok, call} <- State.block_jump_call(state, idx, stack_depths) do
      {:ok, state.body ++ [call]}
    end
  end

  defp lower_block(instructions, idx, next_entry, arg_count, state, stack_depths) do
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
              stack_depths
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
          stack_depths
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
         stack_depths
       ) do
    case Ops.lower_instruction(instruction, idx, next_entry, arg_count, state, stack_depths) do
      {:ok, next_state} ->
        lower_block(instructions, idx + 1, next_entry, arg_count, next_state, stack_depths)

      {:done, body} ->
        {:ok, body}

      {:error, _} = error ->
        error
    end
  end

  defp lower_catch_suffix(instructions, idx, next_entry, arg_count, state, stack_depths, target) do
    with :ok <- ensure_catch_region_supported(instructions, idx, target),
         {saved_stack, state} <- freeze_stack(state),
         {:ok, handler_call} <-
           State.block_jump_call_values(
             target,
             stack_depths,
             State.current_slots(state),
             [State.var("Caught#{idx}") | saved_stack]
           ),
         {:ok, try_body} <-
           lower_block(
             instructions,
             idx + 1,
             next_entry,
             arg_count,
             %{state | body: [], stack: [State.literal(target) | saved_stack]},
             stack_depths
           ) do
      {:ok,
       state.body ++ [State.try_catch_expr(try_body, State.var("Caught#{idx}"), [handler_call])]}
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
