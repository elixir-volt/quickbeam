defmodule QuickBEAM.VM.Runtime.GlobalsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Runtime.Globals

  setup do
    Heap.reset()
    :ok
  end

  test "builder installs standard, host, and globalThis bindings" do
    bindings = Globals.build()

    assert %{"Object" => _} = bindings
    assert %{"Array" => _} = bindings
    assert %{"Promise" => _} = bindings
    assert %{"parseInt" => _} = bindings
    assert %{"Beam" => _} = bindings
    assert %{"$262" => _} = bindings
    assert {:obj, global_ref} = bindings["globalThis"]
    global_this = Heap.get_obj(global_ref)
    assert global_this["globalThis"] == {:obj, global_ref}
    assert global_this["Object"] == bindings["Object"]
    assert global_this["Beam"] == bindings["Beam"]
  end

  test "registry keeps standard global construction separate from host bindings" do
    registry = Globals.Registry.bindings()

    assert %{"Object" => _} = registry
    assert %{"Math" => _} = registry
    assert %{"parseFloat" => _} = registry
    refute Map.has_key?(registry, "Beam")
    refute Map.has_key?(registry, "URL")
  end

  test "numeric globals live under the Globals namespace" do
    assert Globals.Numeric.parse_int(["10", 10], nil) == 10
    assert Globals.Numeric.parse_float(["1.5"], nil) == 1.5
    assert Globals.Numeric.nan?([:nan], nil)
    assert Globals.Numeric.finite?([10], nil)
  end
end
