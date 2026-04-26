defmodule QuickBEAM.VM.Execution.Trace do
  @moduledoc "Process-local execution frame trace used for JavaScript stack construction."

  @key :qb_active_frames

  @doc "Returns the active JavaScript call frames for the current process."
  def get_frames, do: Process.get(@key, [])

  @doc "Pushes a function frame onto the process-local execution trace."
  def push(fun) do
    Process.put(@key, [%{fun: fun, pc: 0} | get_frames()])
  end

  @doc "Pops the current function frame from the process-local execution trace."
  def pop do
    case Process.get(@key, []) do
      [_ | rest] -> Process.put(@key, rest)
      [] -> :ok
    end
  end

  @doc "Updates the program counter of the current trace frame."
  def update_pc(pc) do
    case Process.get(@key, []) do
      [frame | rest] -> Process.put(@key, [%{frame | pc: pc} | rest])
      [] -> :ok
    end
  end
end
