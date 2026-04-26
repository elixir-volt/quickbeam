defmodule QuickBEAM.VM.Compiler.Lowering.Ops do
  @moduledoc "Per-opcode lowering: translates each QuickJS bytecode instruction into Erlang abstract-form expressions."

  alias QuickBEAM.VM.Compiler.Analysis.CFG

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

  @doc "Lowers one bytecode instruction into compiler state changes."
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

    with :not_handled <- Stack.lower(state, constants, arg_count, name_args),
         :not_handled <- Locals.lower(state, name_args),
         :not_handled <- Globals.lower(state, name_args),
         :not_handled <- Arithmetic.lower(state, name_args),
         :not_handled <- Objects.lower(state, name_args),
         :not_handled <- Calls.lower(state, name_args),
         :not_handled <-
           Control.lower(state, idx, next_entry, stack_depths, inline_targets, name_args),
         :not_handled <- Iterators.lower(state, name_args),
         :not_handled <- Classes.lower(state, name_args),
         :not_handled <- Generators.lower(state, next_entry, stack_depths, name_args),
         :not_handled <- WithScope.lower(state, name_args) do
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
end
