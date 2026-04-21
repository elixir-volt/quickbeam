defmodule QuickBEAM.VM.Execution.Trace do
  @moduledoc false

  @key :qb_active_frames

  def push(fun) do
    Process.put(@key, [%{fun: fun, pc: 0} | Process.get(@key, [])])
  end

  def pop do
    case Process.get(@key, []) do
      [_ | rest] -> Process.put(@key, rest)
      [] -> :ok
    end
  end

  def update_pc(pc) do
    case Process.get(@key, []) do
      [frame | rest] -> Process.put(@key, [%{frame | pc: pc} | rest])
      [] -> :ok
    end
  end
end
