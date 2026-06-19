defmodule QuickBEAM.VM.Compiler.FunctionInfo do
  @moduledoc "Shared helpers for compiler/interpreter function metadata."

  def code_key(%QuickBEAM.VM.Function{id: id}) when is_integer(id), do: {:function, id}

  def code_key(%QuickBEAM.VM.Function{instructions: instructions}) when is_tuple(instructions),
    do: {:instructions, :erlang.phash2(instructions)}

  def instructions(%QuickBEAM.VM.Function{instructions: instructions})
      when is_tuple(instructions),
      do: {:ok, Tuple.to_list(instructions)}

  def instructions(%QuickBEAM.VM.Function{}), do: {:error, :missing_instructions}
end
