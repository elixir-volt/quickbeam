defmodule QuickBEAM.VM.Host.BeamAPITest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.BeamAPI

  setup do
    Heap.reset()
    :ok
  end

  test "Beam bridge is exposed as a host binding" do
    assert %{"Beam" => {:obj, _}} = BeamAPI.bindings()
  end
end
