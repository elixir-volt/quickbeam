defmodule QuickBEAM.VM.Execution.Eval do
  @moduledoc "Boundary for compiling source and evaluating QuickJS bytecode in the interpreter."

  alias QuickBEAM.VM.{BytecodeParser, Interpreter, Runtime}

  def compile_and_eval(runtime_pid, code, opts \\ []) do
    with {:ok, bytecode} <- QuickBEAM.Runtime.compile(runtime_pid, code),
         {:ok, parsed} <- BytecodeParser.decode(bytecode) do
      Interpreter.eval(
        parsed.value,
        [],
        Map.merge(%{gas: Runtime.gas_budget(), runtime_pid: runtime_pid}, Map.new(opts)),
        parsed.atoms
      )
    end
  end
end
