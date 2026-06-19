defmodule QuickBEAM.VM.RegexpStateGCTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Execution.RegexpState
  alias QuickBEAM.VM.Heap

  setup do
    Heap.reset()
    :ok
  end

  test "RegExp property side table marks stored heap values" do
    {:obj, object_ref} = property_value = Heap.wrap(%{"kept" => true})
    regexp_ref = make_ref()
    regexp = {:regexp, nil, "", regexp_ref}

    RegexpState.put(regexp_ref, "custom", property_value)
    Heap.mark_and_sweep([regexp])

    assert RegexpState.fetch(regexp_ref, "custom") == {:ok, property_value}
    assert %{"kept" => true} = Heap.get_obj(object_ref, :missing)
  end

  test "RegExp property side tables are swept when RegExp is unreachable" do
    {:obj, object_ref} = property_value = Heap.wrap(%{"swept" => true})
    regexp_ref = make_ref()

    RegexpState.put(regexp_ref, "custom", property_value)
    Heap.mark_and_sweep([])

    assert RegexpState.get(regexp_ref) == %{}
    assert Heap.get_obj(object_ref, :missing) == :missing
  end
end
