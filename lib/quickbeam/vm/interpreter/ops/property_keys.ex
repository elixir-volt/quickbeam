defmodule QuickBEAM.VM.Interpreter.Ops.PropertyKeys do
  @moduledoc "Property-key coercion helpers for interpreter object operations."

  alias QuickBEAM.VM.RuntimeState
  alias QuickBEAM.VM.ObjectModel.PropertyKey

  def to_property_key(key, ctx) do
    try do
      {:ok, PropertyKey.to_property_key(key), RuntimeState.refresh_globals(ctx)}
    catch
      {:js_throw, error} -> {:throw, error, RuntimeState.current_or(ctx)}
    end
  end
end
