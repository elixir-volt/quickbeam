defmodule QuickBEAM.VM.RuntimeStateTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Compiler.RuntimeHelpers.Iterators
  alias QuickBEAM.VM.{Heap, RuntimeState}

  test "iterator result owners can be consumed" do
    result = {:obj, make_ref()}
    iterator = {:obj, make_ref()}

    RuntimeState.put_iterator_result_owner(result, iterator)

    assert RuntimeState.get_iterator_result_owner(result) == iterator
    assert RuntimeState.consume_iterator_result_owner(result) == iterator
    assert RuntimeState.get_iterator_result_owner(result) == nil
  end

  test "iterator value_done consumes successful result owners" do
    result = Heap.wrap(%{"done" => false, "value" => 42})
    iterator = {:obj, make_ref()}

    RuntimeState.put_iterator_result_owner(result, iterator)

    assert Iterators.value_done(result) == {false, 42}
    assert RuntimeState.get_iterator_result_owner(result) == nil
  end
end
