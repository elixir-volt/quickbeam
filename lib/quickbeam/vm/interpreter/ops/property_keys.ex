defmodule QuickBEAM.VM.Interpreter.Ops.PropertyKeys do
  @moduledoc "Property-key coercion helpers for interpreter object operations."

  alias QuickBEAM.VM.Interpreter.Completion
  alias QuickBEAM.VM.ObjectModel.PropertyKey

  def to_property_key(key, ctx) do
    try do
      {:ok, PropertyKey.to_property_key(key), Completion.refresh_globals(ctx)}
    catch
      {:js_throw, error} -> Completion.throw_result(error, ctx)
    end
  end
end
