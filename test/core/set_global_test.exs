defmodule QuickBEAM.Core.SetGlobalTest do
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

  test "set and read a string", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "greeting", "hello")
    assert {:ok, "hello"} = QuickBEAM.eval(rt, "greeting")
  end

  test "set and read a number", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "count", 42)
    assert {:ok, 42} = QuickBEAM.eval(rt, "count")
  end

  test "set and read a map", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "config", %{"theme" => "dark", "limit" => 100})
    assert {:ok, "dark"} = QuickBEAM.eval(rt, "config.theme")
    assert {:ok, 100} = QuickBEAM.eval(rt, "config.limit")
  end

  test "set and read a list", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "items", [1, 2, 3])
    assert {:ok, 3} = QuickBEAM.eval(rt, "items.length")
    assert {:ok, 6} = QuickBEAM.eval(rt, "items.reduce((a, b) => a + b, 0)")
  end

  test "set boolean", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "enabled", true)
    assert {:ok, true} = QuickBEAM.eval(rt, "enabled")
  end

  test "set nil becomes null", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "empty", nil)
    assert {:ok, true} = QuickBEAM.eval(rt, "empty === null")
  end

  test "overwrite existing global", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "x", 1)
    assert {:ok, 1} = QuickBEAM.eval(rt, "x")
    :ok = QuickBEAM.set_global(rt, "x", 2)
    assert {:ok, 2} = QuickBEAM.eval(rt, "x")
  end

  test "global persists across evals", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "persistent", "yes")
    assert {:ok, "yes"} = QuickBEAM.eval(rt, "persistent")
    assert {:ok, "yes"} = QuickBEAM.eval(rt, "persistent")
  end

  test "global accessible from call", %{rt: rt} do
    :ok = QuickBEAM.set_global(rt, "multiplier", 10)
    QuickBEAM.eval(rt, "function scale(x) { return x * multiplier }")
    assert {:ok, 50} = QuickBEAM.call(rt, "scale", [5])
  end

  test "nested object", %{rt: rt} do
    data = %{"users" => [%{"name" => "Alice"}, %{"name" => "Bob"}]}
    :ok = QuickBEAM.set_global(rt, "data", data)
    assert {:ok, "Alice"} = QuickBEAM.eval(rt, "data.users[0].name")
  end
end
