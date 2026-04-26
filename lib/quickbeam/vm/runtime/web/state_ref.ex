defmodule QuickBEAM.VM.Runtime.Web.StateRef do
  @moduledoc "Small reference-backed state container used by Web API builtin objects."

  alias QuickBEAM.VM.Heap

  @doc "Creates a new heap-backed state reference initialized with `initial`."
  def new(initial) do
    ref = make_ref()
    put(ref, initial)
    ref
  end

  @doc "Reads the value stored at `ref`, returning `default` if it is absent."
  def get(ref, default \\ %{}) do
    Heap.get_obj(ref, default)
  end

  @doc "Stores `value` at `ref` and returns the stored value."
  def put(ref, value) do
    Heap.put_obj(ref, value)
    value
  end

  @doc "Updates the value at `ref` by applying `fun` to the current or default value."
  def update(ref, default \\ %{}, fun) when is_function(fun, 1) do
    new_value =
      ref
      |> get(default)
      |> fun.()

    put(ref, new_value)
  end
end
