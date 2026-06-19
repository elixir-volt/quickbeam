defmodule QuickBEAM.VM.Compiler.Lowering.ExceptionRegions do
  @moduledoc "Lowers catch regions and finally/gosub control-flow fragments."

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Driver, Emit, Ops, Slots, State}
  alias QuickBEAM.VM.OpcodeSpec

  @doc "Lowers a catch instruction and its protected suffix."
  def catch_suffix(
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
        callbacks
      ) do
    with :ok <- ensure_catch_region_supported(instructions, idx, target),
         {saved_stack, state} <- Emit.freeze_stack(state),
         {:ok, handler_call} <-
           State.block_jump_call_values(
             target,
             stack_depths,
             State.ctx_expr(state),
             Slots.current_slots(state),
             [Builder.var("Caught#{idx}") | saved_stack],
             Slots.current_capture_cells(state),
             state.frame_mode
           ),
         {:ok, try_body} <-
           Driver.lower_block(callbacks, [
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
           ]) do
      {:ok,
       Enum.reverse([
         Builder.try_catch_expr(try_body, Builder.var("Caught#{idx}"), [handler_call])
         | state.body
       ])}
    end
  end

  @doc "Lowers a gosub/finally entry and resumes the encoded continuation."
  def gosub_suffix(
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
        callbacks
      ) do
    state = Emit.push(state, Builder.atom(:return_addr), :unknown)

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
           {:block, idx + 1, next_entry, arg_count},
           callbacks
         ) do
      {:ok, body} when is_list(body) -> {:ok, body}
      {:done, body} when is_list(body) -> {:ok, body}
      {:done, terminal_state} -> {:ok, Enum.reverse(terminal_state.body)}
      {:error, _} = error -> error
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
         _continuation,
         _callbacks
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
         continuation,
         callbacks
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
              continuation,
              callbacks
            )

          {:ok, name} ->
            if OpcodeSpec.control_flow_family(name) == :finally_control do
              {:error, {:unsupported_finally_opcode, name, idx}}
            else
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
                continuation,
                callbacks
              )
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
              continuation,
              callbacks
            )
        end

      {op, _args} ->
        case CFG.opcode_name(op) do
          {:ok, :gosub} ->
            state = Emit.push(state, Builder.atom(:return_addr), :unknown)
            target = hd(elem(instruction, 1))

            lower_finally_inline(
              instructions,
              size,
              target,
              state,
              stack_depths,
              constants,
              entries,
              inline_targets,
              target,
              {:finally, idx + 1, finally_entry, continuation},
              callbacks
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
              hd(elem(instruction, 1)),
              callbacks
            )

          {:ok, name} ->
            if OpcodeSpec.control_flow_family(name) == :goto do
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
                  continuation,
                  callbacks
                )
              else
                State.goto(state, target, stack_depths)
              end
            else
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
                continuation,
                callbacks
              )
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
              continuation,
              callbacks
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
         target,
         callbacks
       ) do
    with :ok <- ensure_catch_region_supported(instructions, idx, target),
         {saved_stack, state} <- Emit.freeze_stack(state),
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
             continuation,
             callbacks
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
             continuation,
             callbacks
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
         continuation,
         callbacks
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
           continuation,
           callbacks
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
         {:block, idx, next_entry, arg_count},
         callbacks
       ) do
    with {:ok, _return_addr, state} <- Emit.pop(state) do
      Driver.lower_block(callbacks, [
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
      ])
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
         {:finally, idx, finally_entry, continuation},
         callbacks
       ) do
    with {:ok, _return_addr, state} <- Emit.pop(state) do
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
        continuation,
        callbacks
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
         continuation,
         callbacks
       ) do
    case Ops.lower_instruction(
           instruction,
           idx,
           CFG.next_entry(entries, idx),
           state.arg_count,
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
          continuation,
          callbacks
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
