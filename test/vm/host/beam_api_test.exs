defmodule QuickBEAM.VM.Host.BEAMAPITest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.BEAMAPI

  setup do
    Heap.reset()
    :ok
  end

  test "Beam bridge is exposed as a host binding" do
    assert %{"Beam" => {:obj, _}} = BEAMAPI.bindings()
  end
end
