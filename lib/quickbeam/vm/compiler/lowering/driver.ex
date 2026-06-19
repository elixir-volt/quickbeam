defmodule QuickBEAM.VM.Compiler.Lowering.Driver do
  @moduledoc "Callback boundary used by extracted lowering modules to resume the main lowering loop."

  defstruct [:lower_block, :lower_non_branch_instruction]

  @doc "Builds a lowering driver from the main lowering loop callbacks."
  def new(opts) do
    struct!(__MODULE__, opts)
  end

  @doc "Resumes normal block lowering."
  def lower_block(%__MODULE__{lower_block: lower_block}, args) do
    apply(lower_block, args)
  end

  @doc "Resumes non-branch instruction lowering."
  def lower_non_branch_instruction(
        %__MODULE__{lower_non_branch_instruction: lower_non_branch_instruction},
        args
      ) do
    apply(lower_non_branch_instruction, args)
  end
end
