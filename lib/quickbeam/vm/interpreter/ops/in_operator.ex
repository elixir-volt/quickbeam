defmodule QuickBEAM.VM.Interpreter.Ops.InOperator do
  @moduledoc "Interpreter helper for JavaScript in operator semantics."

  import QuickBEAM.VM.Value, only: [is_closure: 1, is_object: 1]

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{InternalMethods, PropertyKey}
  alias QuickBEAM.VM.Semantics.Values

  def evaluate(key, obj) do
    unless object_like?(obj) do
      throw(
        {:js_throw,
         Heap.make_error(
           "Cannot use 'in' operator to search for '#{Values.stringify(key)}' in #{Values.stringify(obj)}",
           "TypeError"
         )}
      )
    end

    InternalMethods.has_property(obj, property_key(key))
  end

  defp object_like?(obj) do
    is_object(obj) or match?({:builtin, _, _}, obj) or is_closure(obj) or
      match?(%QuickBEAM.VM.Function{}, obj) or match?({:bound, _, _, _, _}, obj) or
      match?({:qb_arr, _}, obj) or is_list(obj) or is_map(obj)
  end

  defp property_key(key), do: PropertyKey.to_property_key(key)
end
