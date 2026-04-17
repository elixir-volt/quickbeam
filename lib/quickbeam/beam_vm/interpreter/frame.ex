defmodule QuickBEAM.BeamVM.Interpreter.Frame do
  @type t :: tuple()

  # Tuple layout: {pc, locals, constants, var_refs, stack_size, instructions, local_to_vref}
  @pc 0
  @locals 1
  @constants 2
  @var_refs 3
  @insns 5
  @l2v 6

  defmacro pc, do: @pc
  defmacro locals, do: @locals
  defmacro constants, do: @constants
  defmacro var_refs, do: @var_refs
  defmacro insns, do: @insns
  defmacro l2v, do: @l2v

  def new(pc, locals, constants, var_refs, stack_size, instructions, local_to_vref) do
    {pc, locals, constants, var_refs, stack_size, instructions, local_to_vref}
  end
end
