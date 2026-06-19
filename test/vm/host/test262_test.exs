defmodule QuickBEAM.VM.Host.Test262Test do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.Test262

  setup do
    Heap.reset()
    :ok
  end

  test "$262 exposes compatibility host hooks" do
    assert {:obj, ref} = Test262.object()
    object = Heap.get_obj(ref)

    assert Map.has_key?(object, "createRealm")
    assert Map.has_key?(object, "detachArrayBuffer")
  end
end
