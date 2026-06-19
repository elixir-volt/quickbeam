defmodule QuickBEAM.VM.Heap.GCTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap

  setup do
    Heap.reset()
    :ok
  end

  test "gc preserves side-table metadata for live object owners" do
    {:obj, ref} = obj = Heap.wrap(%{"x" => 1})

    Heap.freeze(ref)
    Heap.put_prop_desc(ref, "x", %{enumerable: false, configurable: false, writable: false})
    Heap.put_array_prop(ref, "named", Heap.wrap(%{"kept" => true}))

    Heap.gc([obj])

    assert Heap.frozen?(ref)
    refute Heap.extensible?(ref)

    assert Heap.get_prop_desc(ref, "x") == %{
             enumerable: false,
             configurable: false,
             writable: false
           }

    assert match?({:obj, _}, Heap.get_array_prop(ref, "named"))
    refute Heap.gc_needed?()
  end

  test "gc marks through live array side-table values" do
    {:obj, array_ref} = array = Heap.wrap([])
    {:obj, child_ref} = child = Heap.wrap(%{"kept" => true})

    Heap.put_array_prop(array_ref, "child", child)

    Heap.gc([array])

    assert Map.get(Heap.get_obj(child_ref), "kept") == true
  end

  test "gc sweeps side-table metadata for dead object owners" do
    {:obj, ref} = Heap.wrap(%{"x" => 1})
    Heap.freeze(ref)
    Heap.put_prop_desc(ref, "x", %{enumerable: false})
    Heap.put_array_prop(ref, "named", 1)

    Heap.gc([])

    refute Heap.frozen?(ref)
    assert Heap.extensible?(ref)
    assert Heap.get_prop_desc(ref, "x") == nil
    assert Heap.get_array_props(ref) == %{}
    assert Process.get({:qb_prop_desc_index, ref}) == nil
  end

  test "gc marks through indexed constructor descriptor values" do
    ctor = {:builtin, "Ctor", fn _, _ -> :undefined end}
    {:obj, child_ref} = child = Heap.wrap(%{"kept" => true})

    Heap.put_ctor_prop_desc(ctor, "child", %{value: child})

    Heap.gc([ctor])

    assert Map.get(Heap.get_obj(child_ref), "kept") == true
  end

  test "gc resets allocation accounting flags" do
    Process.put(:qb_gc_needed, true)
    Process.put(:qb_alloc_count, 999)
    Process.put(:qb_gc_threshold, 999)

    obj = Heap.wrap(%{})
    Heap.gc([obj])

    refute Heap.gc_needed?()
    assert Process.get(:qb_alloc_count) >= 1
    assert Process.get(:qb_gc_threshold) > Process.get(:qb_alloc_count)
  end
end
