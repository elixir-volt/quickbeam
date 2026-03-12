defmodule QuickBEAM.Core.TimeoutTest do
  use ExUnit.Case, async: true

  test "eval with timeout completes normally" do
    {:ok, rt} = QuickBEAM.start()
    assert {:ok, 42} = QuickBEAM.eval(rt, "42", timeout: 5000)
    QuickBEAM.stop(rt)
  end

  test "eval with timeout aborts infinite loop" do
    {:ok, rt} = QuickBEAM.start()
    assert {:error, _} = QuickBEAM.eval(rt, "while(true) {}", timeout: 100)
    assert {:ok, 1} = QuickBEAM.eval(rt, "1")
    QuickBEAM.stop(rt)
  end

  test "call with timeout aborts infinite loop" do
    {:ok, rt} = QuickBEAM.start()
    QuickBEAM.eval(rt, "function spin() { while(true) {} }")
    assert {:error, _} = QuickBEAM.call(rt, "spin", [], timeout: 100)
    assert {:ok, 1} = QuickBEAM.eval(rt, "1")
    QuickBEAM.stop(rt)
  end

  test "eval without timeout has no limit" do
    {:ok, rt} = QuickBEAM.start()
    assert {:ok, 5_000_000} = QuickBEAM.eval(rt, "let s = 0; for (let i = 0; i < 5_000_000; i++) s += 1; s")
    QuickBEAM.stop(rt)
  end
end
