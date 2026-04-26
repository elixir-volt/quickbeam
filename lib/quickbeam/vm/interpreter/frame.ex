defmodule QuickBEAM.VM.Interpreter.Frame do
  @moduledoc "Tuple-backed interpreter frame layout helpers."
  @type t :: {tuple(), tuple(), tuple(), non_neg_integer(), tuple(), map()}

  # Tuple layout: {locals, constants, var_refs, _stack_size (unused), instructions, local_to_vref}
  @locals 0
  @constants 1
  @var_refs 2
  @insns 4
  @l2v 5

  @doc "Tuple index for the frame local-slot tuple."
  defmacro locals, do: @locals
  @doc "Tuple index for the frame constant pool."
  defmacro constants, do: @constants
  @doc "Tuple index for captured variable references."
  defmacro var_refs, do: @var_refs
  @doc "Tuple index for decoded instructions."
  defmacro insns, do: @insns
  @doc "Tuple index for the local-to-var-ref mapping."
  defmacro l2v, do: @l2v

  @doc "Builds an interpreter frame tuple."
  def new(locals, constants, var_refs, stack_size, instructions, local_to_vref) do
    {locals, constants, var_refs, stack_size, instructions, local_to_vref}
  end
end
