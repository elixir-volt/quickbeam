defmodule QuickBEAM.VM.Runtime.Web.IteratorResult do
  @moduledoc false

  alias QuickBEAM.VM.{Heap, PromiseState}

  def value(value), do: Heap.wrap(%{"value" => value, "done" => false})
  def done, do: Heap.wrap(%{"value" => :undefined, "done" => true})

  def resolved_value(value), do: PromiseState.resolved(value(value))
  def resolved_done, do: PromiseState.resolved(done())
end
