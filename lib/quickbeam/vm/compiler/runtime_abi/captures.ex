defmodule QuickBEAM.VM.Compiler.RuntimeABI.Captures do
  @moduledoc false

  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Captures, as: RuntimeCaptures

  def read_capture_cell(ctx, cell, slot_value),
    do: RuntimeCaptures.read_cell(ctx, cell, slot_value)

  def ensure_capture_cell(ctx, cell, value), do: RuntimeCaptures.ensure_cell(ctx, cell, value)
  def close_capture_cell(ctx, cell, value), do: RuntimeCaptures.close_cell(ctx, cell, value)
  def sync_capture_cell(ctx, cell, value), do: RuntimeCaptures.sync_cell(ctx, cell, value)
  def get_capture(ctx, key), do: RuntimeCaptures.get(ctx, key)
end
