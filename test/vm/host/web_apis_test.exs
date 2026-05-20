defmodule QuickBEAM.VM.Host.WebAPIsTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.VM.Heap
  alias QuickBEAM.VM.Host.WebAPIs

  setup do
    Heap.reset()
    :ok
  end

  test "aggregates Web API and Beam host bindings" do
    bindings = WebAPIs.bindings()

    assert %{"Beam" => {:obj, _}} = bindings
    assert %{"URL" => _} = bindings
    assert %{"TextEncoder" => _} = bindings
    assert %{"setTimeout" => _} = bindings
  end
end
