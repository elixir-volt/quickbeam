defmodule QuickBEAM.StorageTest do
  use ExUnit.Case, async: false

  setup do
    QuickBEAM.Storage.init()
    QuickBEAM.Storage.clear([])
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)

    {:ok, rt: rt}
  end

  describe "localStorage" do
    test "setItem and getItem", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, ~s[localStorage.getItem("x")])

      QuickBEAM.eval(rt, ~s[localStorage.setItem("x", "hello")])

      assert {:ok, "hello"} = QuickBEAM.eval(rt, ~s[localStorage.getItem("x")])
    end

    test "removeItem", %{rt: rt} do
      QuickBEAM.eval(rt, ~s[localStorage.setItem("y", "val")])
      QuickBEAM.eval(rt, ~s[localStorage.removeItem("y")])

      assert {:ok, nil} = QuickBEAM.eval(rt, ~s[localStorage.getItem("y")])
    end

    test "clear", %{rt: rt} do
      QuickBEAM.eval(rt, ~s[localStorage.setItem("a", "1")])
      QuickBEAM.eval(rt, ~s[localStorage.setItem("b", "2")])
      QuickBEAM.eval(rt, ~s[localStorage.clear()])

      assert {:ok, 0} = QuickBEAM.eval(rt, "localStorage.length")
    end

    test "length", %{rt: rt} do
      assert {:ok, 0} = QuickBEAM.eval(rt, "localStorage.length")

      QuickBEAM.eval(rt, ~s[localStorage.setItem("k1", "v1")])
      QuickBEAM.eval(rt, ~s[localStorage.setItem("k2", "v2")])

      assert {:ok, 2} = QuickBEAM.eval(rt, "localStorage.length")
    end

    test "key(index)", %{rt: rt} do
      QuickBEAM.eval(rt, ~s[localStorage.setItem("alpha", "1")])
      QuickBEAM.eval(rt, ~s[localStorage.setItem("beta", "2")])

      assert {:ok, "alpha"} = QuickBEAM.eval(rt, "localStorage.key(0)")
      assert {:ok, "beta"} = QuickBEAM.eval(rt, "localStorage.key(1)")
      assert {:ok, nil} = QuickBEAM.eval(rt, "localStorage.key(99)")
    end

    test "shared across runtimes", %{rt: rt} do
      {:ok, rt2} = QuickBEAM.start()

      QuickBEAM.eval(rt, ~s[localStorage.setItem("shared", "from rt1")])

      assert {:ok, "from rt1"} =
               QuickBEAM.eval(rt2, ~s[localStorage.getItem("shared")])

      QuickBEAM.stop(rt2)
    end

    test "values are coerced to strings", %{rt: rt} do
      QuickBEAM.eval(rt, ~s[localStorage.setItem("num", 42)])

      assert {:ok, "42"} = QuickBEAM.eval(rt, ~s[localStorage.getItem("num")])
    end
  end
end
