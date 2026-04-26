defmodule QuickBEAM.VM.Runtime.Web.IteratorResult do
  @moduledoc "Constructors for JavaScript iterator result objects and resolved promise wrappers."

  alias QuickBEAM.VM.{Heap, PromiseState}

  @doc "Builds a non-final JavaScript iterator result object for `value`."
  def value(value), do: Heap.wrap(%{"value" => value, "done" => false})
  @doc "Builds a final JavaScript iterator result object."
  def done, do: Heap.wrap(%{"value" => :undefined, "done" => true})

  @doc "Builds a resolved promise containing a non-final iterator result."
  def resolved_value(value), do: PromiseState.resolved(value(value))
  @doc "Builds a resolved promise containing a final iterator result."
  def resolved_done, do: PromiseState.resolved(done())
end
