defmodule QuickBEAM.VM.Heap.StoreTest do
  use ExUnit.Case, async: false

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.ObjectModel.{Define, Get, OwnProperty, Put}

  setup do
    Heap.reset()
    :ok
  end

  test "raw_fetch reads shape-backed data and reports missing keys" do
    {:obj, ref} = object = Heap.wrap(%{"a" => 1, "b" => 2})
    raw = Heap.get_obj_raw(ref)

    assert Heap.shape?(raw)
    assert Heap.raw_fetch(raw, "a") == {:ok, 1}
    assert Heap.raw_fetch(raw, "missing") == :error
    assert Get.get(object, "b") == 2
  end

  test "put_obj_key updates existing shape fields and extends through heap boundary" do
    {:obj, ref} = object = Heap.wrap(%{"a" => 1})

    Heap.put_obj_key(ref, "a", 2)
    Heap.put_obj_key(ref, "b", 3)

    raw = Heap.get_obj_raw(ref)
    assert Heap.shape?(raw)
    assert Heap.raw_fetch(raw, "a") == {:ok, 2}
    assert Heap.raw_fetch(raw, "b") == {:ok, 3}
    assert Get.get(object, "a") == 2
    assert Get.get(object, "b") == 3
  end

  test "shape-backed accessor setters are exposed through raw helpers" do
    setter = {:builtin, "set x", fn [value], this -> Put.put(this, "seen", value) end}
    {:obj, ref} = object = Heap.wrap(%{"x" => {:accessor, nil, setter}})

    raw = Heap.get_obj_raw(ref)
    assert Heap.raw_accessor_setter(raw, "x") == {:ok, setter}

    Put.put(object, "x", 7)
    assert Get.get(object, "seen") == 7
  end

  test "shape-backed getter-only properties are exposed through raw helpers" do
    getter = {:builtin, "get x", fn _, _ -> 1 end}
    {:obj, ref} = object = Heap.wrap(%{"x" => {:accessor, getter, nil}})

    raw = Heap.get_obj_raw(ref)
    assert Heap.raw_getter_only?(raw, "x")
    assert Get.get(object, "x") == 1
  end

  test "shape prototype and __proto__ updates stay behind heap boundary" do
    proto = Heap.wrap(%{"inherited" => 1})
    {:obj, ref} = object = Heap.wrap(%{"own" => 2})

    assert Heap.put_shape_proto(ref, proto) == :ok
    assert Heap.raw_proto(Heap.get_obj_raw(ref)) == proto
    assert Get.get(object, "inherited") == 1

    next_proto = Heap.wrap(%{"next" => 3})
    Put.put(object, "__proto__", next_proto)
    assert Heap.raw_proto(Heap.get_obj_raw(ref)) == next_proto
    assert Get.get(object, "next") == 3
  end

  test "symbol writes preserve own-key ordering through heap storage" do
    symbol = {:symbol, "s"}
    {:obj, ref} = object = Heap.wrap(%{"a" => 1})

    Put.put(object, symbol, 2)

    raw_map = Heap.get_obj(ref)
    assert Map.get(raw_map, symbol) == 2
    assert OwnProperty.own_keys(object) == ["a", symbol]
  end

  test "CreateDataProperty writes shape-backed ordinary data descriptors" do
    {:obj, ref} = object = Heap.wrap(%{"a" => 1})

    assert Define.create_data_property(object, "b", 2)
    assert Heap.raw_fetch(Heap.get_obj_raw(ref), "b") == {:ok, 2}
    assert Get.get(object, "b") == 2

    assert match?(
             %{writable: true, enumerable: true, configurable: true},
             Heap.get_prop_desc(ref, "b")
           )
  end
end
