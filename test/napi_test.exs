defmodule QuickBEAM.NapiTest do
  use ExUnit.Case, async: true

  @addon_path Path.expand("support/test_addon.node", __DIR__)

  test "load_addon returns exports with expected keys" do
    {:ok, rt} = QuickBEAM.start()
    assert {:ok, exports} = QuickBEAM.load_addon(rt, @addon_path)
    assert is_map(exports)
    assert Map.has_key?(exports, "hello")
    assert Map.has_key?(exports, "add")
    assert Map.has_key?(exports, "concat")
    assert Map.has_key?(exports, "createObject")
    assert Map.has_key?(exports, "getType")
    assert Map.has_key?(exports, "makeArray")
    assert exports["version"] == 42
    QuickBEAM.stop(rt)
  end

  test "load_addon fails with invalid path" do
    {:ok, rt} = QuickBEAM.start()
    assert {:error, _} = QuickBEAM.load_addon(rt, "/nonexistent/addon.node")
    QuickBEAM.stop(rt)
  end

  test "runtime remains functional after loading addon" do
    {:ok, rt} = QuickBEAM.start()
    {:ok, _} = QuickBEAM.load_addon(rt, @addon_path)
    assert {:ok, 42} = QuickBEAM.eval(rt, "21 + 21")
    assert {:ok, "hello"} = QuickBEAM.eval(rt, "'hello'")
    QuickBEAM.stop(rt)
  end

  test "can load addon multiple times without crash" do
    {:ok, rt} = QuickBEAM.start()
    assert {:ok, _} = QuickBEAM.load_addon(rt, @addon_path)
    assert {:ok, _} = QuickBEAM.load_addon(rt, @addon_path)
    assert {:ok, 1} = QuickBEAM.eval(rt, "1")
    QuickBEAM.stop(rt)
  end
end
