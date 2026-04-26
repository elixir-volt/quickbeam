defmodule QuickBEAM.VM.Runtime.Web.StateRef do
  @moduledoc false

  alias QuickBEAM.VM.Heap

  def new(initial) do
    ref = make_ref()
    put(ref, initial)
    ref
  end

  def get(ref, default \\ %{}) do
    Heap.get_obj(ref, default)
  end

  def put(ref, value) do
    Heap.put_obj(ref, value)
    value
  end

  def update(ref, default \\ %{}, fun) when is_function(fun, 1) do
    new_value =
      ref
      |> get(default)
      |> fun.()

    put(ref, new_value)
  end
end
