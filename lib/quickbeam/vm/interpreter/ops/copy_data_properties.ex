defmodule QuickBEAM.VM.Interpreter.Ops.CopyDataProperties do
  @moduledoc "Object spread/copy-data-properties helpers for interpreter object operations."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Interpreter.Context
  alias QuickBEAM.VM.ObjectModel.Copy
  alias QuickBEAM.VM.Operands.CopyDataProperties, as: Operand
  alias QuickBEAM.VM.RuntimeState

  def copy(target, source, ctx) do
    try do
      Copy.copy_data_properties(target, source)
      {:ok, refresh_persistent_globals(ctx)}
    catch
      {:js_throw, error} -> {:throw, error, ctx}
    end
  end

  def copy_masked(stack, mask, ctx) do
    %{target_idx: target_idx, source_idx: source_idx, exclude_idx: exclude_idx} =
      Operand.decode(mask)

    target = Enum.at(stack, target_idx)
    source = Enum.at(stack, source_idx)
    exclude = Enum.at(stack, exclude_idx)

    try do
      Copy.copy_data_properties(target, source, exclude)
      {:ok, refresh_persistent_globals(ctx)}
    catch
      {:js_throw, error} -> {:throw, error, RuntimeState.current() || ctx}
    end
  end

  defp refresh_persistent_globals(ctx) do
    case Heap.get_persistent_globals() do
      nil -> ctx
      p when map_size(p) == 0 -> ctx
      p -> Context.mark_dirty(%{ctx | globals: Map.merge(ctx.globals, p)})
    end
  end
end
