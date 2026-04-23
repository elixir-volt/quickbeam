defmodule QuickBEAM.Core.BeamProxyEmptyMapTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  describe "nested empty BEAM map access" do
    test "Object.keys on a nested empty map does not crash", %{rt: rt} do
      :ok =
        QuickBEAM.load_module(
          rt,
          "nested_empty_map",
          "globalThis.nestedKeys = function(obj) { return Object.keys(obj.x).length; };"
        )

      assert {:ok, 0} = QuickBEAM.call(rt, "nestedKeys", [%{x: %{}}])
    end

    test "for-in on a nested empty map does not crash", %{rt: rt} do
      :ok =
        QuickBEAM.load_module(
          rt,
          "nested_for_in",
          "globalThis.nestedForIn = function(obj) { var c = 0; for (var k in obj.x) c++; return c; };"
        )

      assert {:ok, 0} = QuickBEAM.call(rt, "nestedForIn", [%{x: %{}}])
    end

    test "Object.keys on a nested non-empty map works", %{rt: rt} do
      :ok =
        QuickBEAM.load_module(
          rt,
          "nested_nonempty",
          "globalThis.nestedNonEmpty = function(obj) { return Object.keys(obj.x).length; };"
        )

      assert {:ok, 2} = QuickBEAM.call(rt, "nestedNonEmpty", [%{x: %{a: 1, b: 2}}])
    end
  end
end
