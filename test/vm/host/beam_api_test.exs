defmodule QuickBEAM.VM.Host.BEAMTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.BEAM

  setup do
    Heap.reset()
    :ok
  end

  test "Beam bridge is exposed as a host binding" do
    assert %{"Beam" => {:obj, _}} = BEAM.bindings()
  end
end
