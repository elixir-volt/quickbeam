defmodule QuickBEAM.VM.Interpreter.Ops.PropertyKeys do
  @moduledoc "Property-key coercion helpers for interpreter object operations."

  alias QuickBEAM.VM.{GlobalEnvironment, RuntimeState}
  alias QuickBEAM.VM.ObjectModel.PropertyKey

  def to_property_key(key, ctx) do
    try do
      {:ok, PropertyKey.to_property_key(key),
       GlobalEnvironment.refresh(RuntimeState.current_or(ctx))}
    catch
      {:js_throw, error} -> {:throw, error, RuntimeState.current_or(ctx)}
    end
  end
end
