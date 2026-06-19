defmodule QuickBEAM.VM.Interpreter.Ops.CopyDataProperties do
  @moduledoc "Object spread/copy-data-properties helpers for interpreter object operations."

  alias QuickBEAM.VM.ObjectModel.Copy
  alias QuickBEAM.VM.Interpreter.Completion
  alias QuickBEAM.VM.Operands.CopyDataProperties, as: Operand

  def copy(target, source, ctx) do
    try do
      Copy.copy_data_properties(target, source)
      {:ok, Completion.refresh_persistent_globals(ctx)}
    catch
      {:js_throw, error} -> Completion.throw_result(error, ctx)
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
      {:ok, Completion.refresh_persistent_globals(ctx)}
    catch
      {:js_throw, error} -> Completion.throw_result(error, ctx)
    end
  end
end
