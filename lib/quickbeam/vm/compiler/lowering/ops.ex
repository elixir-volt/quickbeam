defmodule QuickBEAM.VM.Compiler.Lowering.Ops do
  @moduledoc "Per-opcode lowering: translates each QuickJS bytecode instruction into Erlang abstract-form expressions."

  alias QuickBEAM.VM.Compiler.Analysis.CFG
  alias QuickBEAM.VM.OpcodeSpec

  alias QuickBEAM.VM.Compiler.Lowering.Ops.{
    Arithmetic,
    Calls,
    Classes,
    Control,
    Generators,
    Globals,
    Iterators,
    Locals,
    Objects,
    Stack,
    WithScope
  }

  @doc "Lowers one VM instruction into compiler state changes."
  def lower_instruction(
        {op, args},
        idx,
        next_entry,
        arg_count,
        state,
        stack_depths,
        constants,
        _entries,
        inline_targets
      ) do
    name = CFG.opcode_name(op)
    name_args = {name, args}

    with :not_handled <-
           lower_registered(
             name,
             state,
             idx,
             next_entry,
             arg_count,
             stack_depths,
             constants,
             inline_targets,
             name_args
           ) do
      case name_args do
        {{:ok, :invalid}, _} ->
          {:error, {:unsupported_opcode, :invalid}}

        {{:error, _} = error, _} ->
          error

        {{:ok, op_name}, _} ->
          {:error, {:unsupported_opcode, op_name}}
      end
    end
  end

  defp lower_registered(
         {:ok, name},
         state,
         idx,
         next_entry,
         arg_count,
         stack_depths,
         constants,
         inline_targets,
         name_args
       ) do
    case OpcodeSpec.lowering_family(name) do
      nil ->
        :not_handled

      family ->
        lower_family(
          family,
          state,
          idx,
          next_entry,
          arg_count,
          stack_depths,
          constants,
          inline_targets,
          name_args
        )
    end
  end

  defp lower_registered(
         {:error, _},
         _state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         _name_args
       ),
       do: :not_handled

  defp lower_family(
         :stack,
         state,
         _idx,
         _next_entry,
         arg_count,
         _stack_depths,
         constants,
         _inline_targets,
         name_args
       ),
       do: Stack.lower(state, constants, arg_count, name_args)

  defp lower_family(
         :locals,
         state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Locals.lower(state, name_args)

  defp lower_family(
         :globals,
         state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Globals.lower(state, name_args)

  defp lower_family(
         :arithmetic,
         state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Arithmetic.lower(state, name_args)

  defp lower_family(
         :objects,
         state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Objects.lower(state, name_args)

  defp lower_family(
         :calls,
         state,
         idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Calls.lower(state, idx, name_args)

  defp lower_family(
         :control,
         state,
         idx,
         next_entry,
         _arg_count,
         stack_depths,
         _constants,
         inline_targets,
         name_args
       ),
       do: Control.lower(state, idx, next_entry, stack_depths, inline_targets, name_args)

  defp lower_family(
         :iterators,
         state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Iterators.lower(state, name_args)

  defp lower_family(
         :classes,
         state,
         _idx,
         _next_entry,
         _arg_count,
         _stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Classes.lower(state, name_args)

  defp lower_family(
         :generators,
         state,
         _idx,
         next_entry,
         _arg_count,
         stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: Generators.lower(state, next_entry, stack_depths, name_args)

  defp lower_family(
         :with_scope,
         state,
         _idx,
         next_entry,
         _arg_count,
         stack_depths,
         _constants,
         _inline_targets,
         name_args
       ),
       do: WithScope.lower(state, next_entry, stack_depths, name_args)
end
