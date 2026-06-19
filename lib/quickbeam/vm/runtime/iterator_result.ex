defmodule QuickBEAM.VM.Runtime.IteratorResult do
  @moduledoc "Construction helpers for ECMAScript iterator result objects."

  use QuickBEAM.VM.Builtin

  import QuickBEAM.VM.Heap.Keys, only: [key_order: 0]

  alias QuickBEAM.VM.Heap

  def done, do: new(:undefined, true)

  def new(value, done) do
    object extends: Heap.get_object_prototype() do
      prop("value", value)
      prop("done", done)
      prop(key_order(), ["done", "value"])
    end
  end
end
