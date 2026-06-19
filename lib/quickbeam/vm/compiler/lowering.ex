defmodule QuickBEAM.VM.Compiler.Lowering do
  @moduledoc """
  VM-instruction-to-Erlang lowering pipeline.

  Lowering translates decoded QuickJS bytecode instructions into Erlang abstract
  forms. It is bytecode-oriented rather than ECMA-grammar-oriented. Complex
  ECMAScript semantics should be emitted as calls to `RuntimeABI` or shared VM
  semantic modules unless a specialization is guarded or proven observationally
  equivalent for the inferred operand types.
  """

  alias QuickBEAM.VM.Compiler.Analysis.{CFG, Stack, Types}

  alias QuickBEAM.VM.Compiler.Lowering.{
    BlockClauses,
    Branches,
    Builder,
    Driver,
    ExceptionRegions,
    ObjectLiteralFastPath
  }

  alias QuickBEAM.VM.Compiler.{Lowering.Ops, Lowering.State}
  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.OpcodeSpec

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
        strict_mode: fun.is_strict_mode,
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
            ExceptionRegions.catch_suffix(
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
              lowering_driver()
            )

          {:ok, :gosub} ->
            ExceptionRegions.gosub_suffix(
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
              lowering_driver()
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
            case ObjectLiteralFastPath.try_lower(instructions, next_entry, idx, arg_count, state) do
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
    branch_sense =
      case CFG.opcode_name(op) do
        {:ok, name} -> OpcodeSpec.control_flow_family(name)
        _ -> nil
      end

    case branch_sense do
      {:branch, sense} ->
        Branches.lower(
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
          lowering_driver()
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

  defp lowering_driver do
    Driver.new(
      lower_block: &lower_block/10,
      lower_non_branch_instruction: &lower_non_branch_instruction/11
    )
  end
end
