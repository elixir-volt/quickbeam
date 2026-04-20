defmodule QuickBEAM.BeamVM.Interpreter.Frame do
  @moduledoc false
  @type t :: {tuple(), tuple(), tuple(), non_neg_integer(), tuple(), map()}

  # Tuple layout: {locals, constants, var_refs, _stack_size (unused), instructions, local_to_vref}
  @locals 0
  @constants 1
  @var_refs 2
  @insns 4
  @l2v 5

  defmacro locals, do: @locals
  defmacro constants, do: @constants
  defmacro var_refs, do: @var_refs
  defmacro insns, do: @insns
  defmacro l2v, do: @l2v

  def new(locals, constants, var_refs, stack_size, instructions, local_to_vref) do
    {locals, constants, var_refs, stack_size, instructions, local_to_vref}
  end
end
