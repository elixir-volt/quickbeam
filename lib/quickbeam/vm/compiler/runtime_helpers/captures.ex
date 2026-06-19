defmodule QuickBEAM.VM.Compiler.RuntimeHelpers.Captures do
  @moduledoc "Capture-cell and closure-capture helpers used by BEAM-compiled JavaScript."

  alias QuickBEAM.VM.Environment.Captures, as: EnvCaptures
  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Context, as: RuntimeContext
  alias QuickBEAM.VM.Interpreter.Closures

  def ensure_cell(_ctx \\ nil, cell, value), do: EnvCaptures.ensure(cell, value)
  def close_cell(_ctx \\ nil, cell, value), do: EnvCaptures.close(cell, value)
  def sync_cell(_ctx \\ nil, cell, value), do: EnvCaptures.sync(cell, value)
  def read_cell(_ctx \\ nil, cell, slot_value), do: EnvCaptures.read(cell, slot_value)

  def get(ctx, key) do
    case RuntimeContext.current_func(ctx) do
      {:closure, captured, _} -> read_var_ref(Map.get(captured, key, :undefined))
      _ -> :undefined
    end
  end

  def put(ctx, key, value) do
    case RuntimeContext.current_func(ctx) do
      {:closure, captured, _} -> write_var_ref(Map.get(captured, key, :undefined), value)
      _ -> :ok
    end

    :ok
  end

  def set(ctx, key, value) do
    put(ctx, key, value)
    value
  end

  defp read_var_ref({:cell, _} = cell), do: Closures.read_cell(cell)
  defp read_var_ref(other), do: other

  defp write_var_ref({:cell, _} = cell, value), do: Closures.write_cell(cell, value)
  defp write_var_ref(_, _), do: :ok
end
