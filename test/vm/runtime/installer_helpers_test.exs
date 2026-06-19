defmodule QuickBEAM.VM.Runtime.InstallerHelpersTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.InstallerHelpers

  test "install_object_parent updates shape prototype instead of creating __proto__ data" do
    {:obj, parent_ref} = parent = Heap.wrap(%{"parent" => true})
    {:obj, ref} = Heap.wrap(%{"constructor" => :ctor})

    assert :ok = InstallerHelpers.install_object_parent(ref, parent)

    raw = Heap.get_obj_raw(ref)
    assert Heap.raw_proto(raw) == parent
    refute match?({:ok, _}, Heap.raw_fetch(raw, "__proto__"))
    assert Heap.get_obj(parent_ref, %{}) != %{}
  end

  test "install_object_parent stores internal prototype separately for map objects" do
    {:obj, parent_ref} = parent = Heap.wrap(%{"parent" => true})
    ref = :erlang.unique_integer([:positive, :monotonic])
    Heap.put_obj(ref, %{"0" => :value, "__proto__" => :visible})

    assert :ok = InstallerHelpers.install_object_parent(ref, parent)

    raw = Heap.get_obj_raw(ref)
    assert Heap.raw_proto(raw) == parent
    assert Map.fetch!(raw, "__proto__") == :visible
    assert Heap.get_obj(parent_ref, %{}) != %{}
  end
end
