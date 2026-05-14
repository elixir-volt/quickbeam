defmodule QuickBEAM.VM.Compiler.Lowering do
  @moduledoc "VM-instruction-to-Erlang lowering pipeline: analyses control flow and types, then emits abstract-form block functions."

  alias QuickBEAM.VM.Compiler.Analysis.{CFG, Stack, Types}
  alias QuickBEAM.VM.Compiler.Lowering.{BlockClauses, Builder, ObjectLiteralFastPath}
  alias QuickBEAM.VM.Compiler.{Lowering.Ops, Lowering.State}
  alias QuickBEAM.VM.Heap

  @large_frame_slot_threshold 200
  @line 1

  @doc "Lowers a VM instruction or function into compiler IR."
  def lower(fun, instructions) do
    entries = CFG.block_entries(instructions)
    slot_count = fun.arg_count + fun.var_count
    frame_mode = if slot_count > @large_frame_slot_threshold, do: :tuple, else: :args
    constants = fun.constants
    instrs = List.to_tuple(instructions)
    size = tuple_size(instrs)
    force_capture_slots = has_catch?(instructions)

    with {:ok, stack_depths} <- Stack.infer_block_stack_depths(instructions, entries),
         {:ok, {entry_types, return_type}} <-
           Types.infer_block_entry_types(fun, instructions, entries, stack_depths) do
      inline_targets = CFG.inlineable_entries(instructions, entries)

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
             frame_mode,
             instrs,
             size,
             entries,
             Map.fetch!(stack_depths, start),
             stack_depths,
             constants,
             inline_targets,
             Map.get(entry_types, start),
             return_type,
             force_capture_slots
           )}
        end

      case Enum.find(blocks, fn {_start, form} -> match?({:error, _}, form) end) do
        nil -> {:ok, {slot_count, Enum.map(blocks, &elem(&1, 1))}}
        {_start, error} -> error
      end
    end
  end

  defp has_catch?(instructions) do
    Enum.any?(instructions, fn {op, _args} ->
      match?({:ok, :catch}, CFG.opcode_name(op))
    end)
  end

  defp block_form(
         fun,
         start,
         arg_count,
         slot_count,
         frame_mode,
         instructions,
         size,
         entries,
         stack_depth,
         stack_depths,
         constants,
         inline_targets,
         entry_type_state,
         return_type,
         force_capture_slots
       ) do
    next_entry = CFG.next_entry(entries, start)

    args = BlockClauses.args(slot_count, stack_depth, frame_mode)

    fast_guards = BlockClauses.guards(slot_count, stack_depth, entry_type_state, frame_mode)

    with {:ok, fast_body} <-
           lower_block(
             instructions,
             size,
             start,
             next_entry,
             arg_count,
             block_state(
               fun,
               arg_count,
               slot_count,
               frame_mode,
               stack_depth,
               return_type,
               entry_type_state,
               true,
               force_capture_slots
             ),
             stack_depths,
             constants,
             entries,
             inline_targets
           ) do
      clauses =
        if fast_guards == [] do
          [{:clause, @line, args, [], fast_body}]
        else
          with {:ok, slow_body} <-
                 lower_block(
                   instructions,
                   size,
                   start,
                   next_entry,
                   arg_count,
                   block_state(
                     fun,
                     arg_count,
                     slot_count,
                     frame_mode,
                     stack_depth,
                     return_type,
                     entry_type_state,
                     false,
                     force_capture_slots
                   ),
                   stack_depths,
                   constants,
                   entries,
                   inline_targets
                 ) do
            [
              {:clause, @line, args, [fast_guards], fast_body},
              {:clause, @line, args, [], slow_body}
            ]
          end
        end

      case clauses do
        {:error, _} = error ->
          error

        clauses ->
          {:function, @line, Builder.block_name(start), length(args), clauses}
      end
    end
  end

  defp block_state(
         fun,
         arg_count,
         slot_count,
         frame_mode,
         stack_depth,
         return_type,
         entry_type_state,
         typed?,
         force_capture_slots
       ) do
    state_opts =
      [
        locals: fun.locals,
        closure_vars: fun.closure_vars,
        atoms: Heap.get_fn_atoms(fun),
        arg_count: arg_count,
        return_type: return_type,
        frame_mode: frame_mode,
        force_capture_slots: force_capture_slots
      ] ++
        case {entry_type_state, typed?} do
          {nil, _} ->
            []

          {entry_type_state, true} ->
            [
              slot_types: entry_type_state.slot_types,
              slot_inits: entry_type_state.slot_inits,
              stack_types: entry_type_state.stack_types
            ]

          {entry_type_state, false} ->
            [slot_inits: entry_type_state.slot_inits]
        end

    State.new(slot_count, stack_depth, state_opts)
  end

  defp lower_block(
         _instructions,
         size,
         idx,
         next_entry,
         arg_count,
         state,
         _stack_depths,
         _constants,
         _entries,
         _inline_targets
       )
       when idx >= size do
    {:error, {:missing_terminator, idx, next_entry, arg_count, state.body}}
  end

  defp lower_block(
         instructions,
         size,
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
        size,
        idx,
        CFG.next_entry(entries, idx),
        arg_count,
        state,
        stack_depths,
        constants,
        entries,
        inline_targets
      )
    else
      with {:ok, call} <- State.block_jump_call(state, idx, stack_depths) do
        {:ok, Enum.reverse([call | state.body])}
      end
    end
  end

  defp lower_block(
         instructions,
         size,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    instruction = elem(instructions, idx)

    case instruction do
      {op, [target]} ->
        case CFG.opcode_name(op) do
          {:ok, :catch} ->
            lower_catch_suffix(
              instructions,
              size,
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
              size,
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
              size,
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

      {op, []} ->
        case CFG.opcode_name(op) do
          {:ok, :object} ->
            case ObjectLiteralFastPath.try_lower(instructions, size, idx, arg_count, state) do
              {:ok, state, skip_to} ->
                lower_block(
                  instructions,
                  size,
                  skip_to,
                  next_entry,
                  arg_count,
                  state,
                  stack_depths,
                  constants,
                  entries,
                  inline_targets
                )

              :not_literal ->
                lower_instruction(
                  instruction,
                  instructions,
                  size,
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
              size,
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
          size,
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
         size,
         idx,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets
       ) do
    case CFG.opcode_name(op) do
      {:ok, :if_false} ->
        lower_branch_instruction(
          instructions,
          size,
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
          size,
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
          size,
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
          size,
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
          size,
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
         size,
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
      size,
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
         size,
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
          size,
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
          size,
          target,
          CFG.next_entry(entries, target),
          arg_count,
          next_state,
          stack_depths,
          constants,
          entries,
          inline_targets
        )

      {:done, body} ->
        {:ok, body}

      {:error, reason} ->
        {:error, {:lowering_failed, idx, opcode_name(instruction), reason}}
    end
  end

  defp opcode_name({op, _args}) do
    case CFG.opcode_name(op) do
      {:ok, name} -> name
      {:error, _} -> :unknown
    end
  end

  defp lower_branch_instruction(
         instructions,
         size,
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
               size,
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
               size,
               next_entry,
               arg_count,
               state,
               stack_depths,
               constants,
               entries,
               inline_targets
             ) do
        truthy = Builder.branch_condition(cond_expr, cond_type)
        false_body = if(sense, do: next_body, else: target_body)
        true_body = if(sense, do: target_body, else: next_body)
        {:ok, Enum.reverse([Builder.branch_case(truthy, false_body, true_body) | state.body])}
      end
    else
      lower_non_branch_instruction(
        {if(sense,
           do: QuickBEAM.VM.Opcodes.num(:if_true),
           else: QuickBEAM.VM.Opcodes.num(:if_false)
         ), [target]},
        instructions,
        size,
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
         _size,
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
         size,
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
        size,
        target,
        CFG.next_entry(entries, target),
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
         size,
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
         {saved_stack, state} <- State.freeze_stack(state),
         {:ok, handler_call} <-
           State.block_jump_call_values(
             target,
             stack_depths,
             State.ctx_expr(state),
             State.current_slots(state),
             [Builder.var("Caught#{idx}") | saved_stack],
             State.current_capture_cells(state)
           ),
         {:ok, try_body} <-
           lower_block(
             instructions,
             size,
             idx + 1,
             next_entry,
             arg_count,
             %{
               state
               | body: [],
                 stack: [Builder.literal(target) | saved_stack],
                 stack_types: [:integer | state.stack_types]
             },
             stack_depths,
             constants,
             entries,
             inline_targets
           ) do
      {:ok,
       Enum.reverse([
         Builder.try_catch_expr(try_body, Builder.var("Caught#{idx}"), [handler_call])
         | state.body
       ])}
    end
  end

  defp lower_gosub_suffix(
         instructions,
         size,
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
    state = State.push(state, Builder.atom(:return_addr), :unknown)

    case lower_finally_inline(
           instructions,
           size,
           target,
           state,
           stack_depths,
           constants,
           entries,
           inline_targets,
           target,
           {:block, idx + 1, next_entry, arg_count}
         ) do
      {:ok, body} when is_list(body) ->
        {:ok, body}

      {:done, body} when is_list(body) ->
        {:ok, body}

      {:done, terminal_state} ->
        {:ok, Enum.reverse(terminal_state.body)}

      {:error, _} = error ->
        error
    end
  end

  defp lower_finally_inline(
         _instructions,
         size,
         idx,
         _state,
         _stack_depths,
         _constants,
         _entries,
         _inline_targets,
         _finally_entry,
         _continuation
       )
       when idx >= size do
    {:error, {:missing_ret, idx}}
  end

  defp lower_finally_inline(
         instructions,
         size,
         idx,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         finally_entry,
         continuation
       ) do
    instruction = elem(instructions, idx)

    case instruction do
      {op, []} ->
        case CFG.opcode_name(op) do
          {:ok, :ret} ->
            resume_finally_continuation(
              instructions,
              size,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              continuation
            )

          {:ok, name} when name in [:catch, :gosub, :goto, :goto8, :goto16] ->
            {:error, {:unsupported_finally_opcode, name, idx}}

          _ ->
            lower_finally_instruction(
              instructions,
              size,
              instruction,
              idx,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              finally_entry,
              continuation
            )
        end

      {op, _args} ->
        case CFG.opcode_name(op) do
          {:ok, :gosub} ->
            state = State.push(state, Builder.atom(:return_addr), :unknown)

            lower_finally_inline(
              instructions,
              size,
              hd(elem(instruction, 1)),
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              hd(elem(instruction, 1)),
              {:finally, idx + 1, finally_entry, continuation}
            )

          {:ok, :catch} ->
            lower_finally_catch(
              instructions,
              size,
              idx,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              finally_entry,
              continuation,
              hd(elem(instruction, 1))
            )

          {:ok, name} when name in [:goto, :goto8, :goto16] ->
            target = hd(elem(instruction, 1))

            if finally_internal_target?(instructions, size, finally_entry, target) do
              lower_finally_inline(
                instructions,
                size,
                target,
                state,
                stack_depths,
                constants,
                entries,
                inline_targets,
                finally_entry,
                continuation
              )
            else
              State.goto(state, target, stack_depths)
            end

          _ ->
            lower_finally_instruction(
              instructions,
              size,
              instruction,
              idx,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              finally_entry,
              continuation
            )
        end
    end
  end

  defp lower_finally_catch(
         instructions,
         size,
         idx,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         finally_entry,
         continuation,
         target
       ) do
    with :ok <- ensure_catch_region_supported(instructions, idx, target),
         {saved_stack, state} <- State.freeze_stack(state),
         {:ok, try_body} <-
           lower_finally_body(
             instructions,
             size,
             idx + 1,
             %{
               state
               | body: [],
                 stack: [Builder.literal(target) | saved_stack],
                 stack_types: [:integer | state.stack_types]
             },
             stack_depths,
             constants,
             entries,
             inline_targets,
             finally_entry,
             continuation
           ),
         {:ok, catch_body} <-
           lower_finally_body(
             instructions,
             size,
             target,
             %{
               state
               | body: [],
                 temp: state.temp + (idx + 1) * 1000,
                 stack: [Builder.var("Caught#{idx}") | saved_stack],
                 stack_types: [:unknown | state.stack_types]
             },
             stack_depths,
             constants,
             entries,
             inline_targets,
             finally_entry,
             continuation
           ) do
      {:done,
       Enum.reverse([
         Builder.try_catch_expr(try_body, Builder.var("Caught#{idx}"), catch_body) | state.body
       ])}
    end
  end

  defp lower_finally_body(
         instructions,
         size,
         idx,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         finally_entry,
         continuation
       ) do
    case lower_finally_inline(
           instructions,
           size,
           idx,
           state,
           stack_depths,
           constants,
           entries,
           inline_targets,
           finally_entry,
           continuation
         ) do
      {:ok, body} when is_list(body) -> {:ok, body}
      {:done, body} when is_list(body) -> {:ok, body}
      {:done, terminal_state} -> {:ok, Enum.reverse(terminal_state.body)}
      {:error, _} = error -> error
    end
  end

  defp finally_internal_target?(instructions, size, finally_entry, target) do
    target >= finally_entry and
      finally_region_contains?(instructions, size, finally_entry, target)
  end

  defp finally_region_contains?(_instructions, _size, idx, target) when idx > target, do: false

  defp finally_region_contains?(instructions, size, idx, target) when idx < size do
    {op, _args} = elem(instructions, idx)

    case CFG.opcode_name(op) do
      {:ok, :ret} -> idx == target
      _ -> idx == target or finally_region_contains?(instructions, size, idx + 1, target)
    end
  end

  defp finally_region_contains?(_instructions, _size, _idx, _target), do: false

  defp resume_finally_continuation(
         instructions,
         size,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         {:block, idx, next_entry, arg_count}
       ) do
    with {:ok, _return_addr, state} <- State.pop(state) do
      lower_block(
        instructions,
        size,
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

  defp resume_finally_continuation(
         instructions,
         size,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         {:finally, idx, finally_entry, continuation}
       ) do
    with {:ok, _return_addr, state} <- State.pop(state) do
      lower_finally_inline(
        instructions,
        size,
        idx,
        state,
        stack_depths,
        constants,
        entries,
        inline_targets,
        finally_entry,
        continuation
      )
    end
  end

  defp lower_finally_instruction(
         instructions,
         size,
         instruction,
         idx,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         finally_entry,
         continuation
       ) do
    case Ops.lower_instruction(
           instruction,
           idx,
           CFG.next_entry(entries, idx),
           0,
           state,
           stack_depths,
           constants,
           entries,
           inline_targets
         ) do
      {:ok, next_state} ->
        lower_finally_inline(
          instructions,
          size,
          idx + 1,
          next_state,
          stack_depths,
          constants,
          entries,
          inline_targets,
          finally_entry,
          continuation
        )

      {:done, body} ->
        {:done,
         %{state | body: Enum.reverse(body), stack: state.stack, stack_types: state.stack_types}}

      {:error, _} = error ->
        error
    end
  end

  defp ensure_catch_region_supported(_instructions, _catch_idx, _target), do: :ok
end
