defmodule QuickBEAM.VM.Compiler.Lowering.Branches do
  @moduledoc "Lowers conditional branches, including inlineable branch target bodies."

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.Compiler.Lowering.{Builder, Driver, Emit, State}

  @doc "Lowers a branch instruction, inlining target bodies when either edge is inlineable."
  def lower(
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
        sense,
        callbacks
      ) do
    if MapSet.member?(inline_targets, target) or MapSet.member?(inline_targets, next_entry) do
      lower_inline_branch(
        instructions,
        size,
        next_entry,
        arg_count,
        state,
        stack_depths,
        constants,
        entries,
        inline_targets,
        target,
        sense,
        callbacks
      )
    else
      lower_regular_branch(
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
        sense,
        callbacks
      )
    end
  end

  defp lower_inline_branch(
         instructions,
         size,
         next_entry,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         target,
         sense,
         callbacks
       ) do
    with {:ok, cond_expr, cond_type, state} <- Emit.pop_typed(state),
         {:ok, target_body} <-
           target_body(
             instructions,
             size,
             target,
             arg_count,
             state,
             stack_depths,
             constants,
             entries,
             inline_targets,
             callbacks
           ),
         {:ok, next_body} <-
           target_body(
             instructions,
             size,
             next_entry,
             arg_count,
             state,
             stack_depths,
             constants,
             entries,
             inline_targets,
             callbacks
           ) do
      truthy = Builder.branch_condition(cond_expr, cond_type)
      false_body = if(sense, do: next_body, else: target_body)
      true_body = if(sense, do: target_body, else: next_body)
      {:ok, Enum.reverse([Builder.branch_case(truthy, false_body, true_body) | state.body])}
    end
  end

  defp lower_regular_branch(
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
         sense,
         driver
       ) do
    opcode =
      if(sense, do: QuickBEAM.VM.Opcodes.num(:if_true), else: QuickBEAM.VM.Opcodes.num(:if_false))

    Driver.lower_non_branch_instruction(driver, [
      {opcode, [target]},
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

  defp target_body(
         _instructions,
         _size,
         nil,
         _arg_count,
         _state,
         _stack_depths,
         _constants,
         _entries,
         _inline_targets,
         _callbacks
       ),
       do: {:error, :missing_branch_fallthrough}

  defp target_body(
         instructions,
         size,
         target,
         arg_count,
         state,
         stack_depths,
         constants,
         entries,
         inline_targets,
         driver
       ) do
    if MapSet.member?(inline_targets, target) do
      Driver.lower_block(driver, [
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
      ])
    else
      with {:ok, call} <- State.block_jump_call(state, target, stack_depths) do
        {:ok, [call]}
      end
    end
  end
end
