defmodule QuickBEAM.VM.Interpreter.Ops.Delete do
  @moduledoc "Delete operator helpers for interpreter object operations."

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.Delete, as: ObjectDelete
  alias QuickBEAM.VM.ObjectModel.Static
  alias QuickBEAM.VM.Semantics.Values

  def nullish_error(obj, key) do
    nullish = if obj == nil, do: "null", else: "undefined"

    Heap.make_error(
      "Cannot delete properties of #{nullish} (deleting '#{Values.stringify(key)}')",
      "TypeError"
    )
  end

  def property(obj, key) do
    case obj do
      {:obj, _} = obj -> ObjectDelete.delete_property(obj, key)
      {:closure, _, _} = fun -> Static.delete_static(fun, key)
      %QuickBEAM.VM.Function{} = fun -> Static.delete_static(fun, key)
      {:builtin, _, _} = fun -> Static.delete_static(fun, key)
      {:bound, _, _, _, _} = fun -> Static.delete_static(fun, key)
      _ -> true
    end
  end
end
