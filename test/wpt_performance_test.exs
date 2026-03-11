defmodule QuickBEAM.WPT.PerformanceTest do
  @moduledoc "Ported from WPT: hr-time-basic.any.js"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "WPT High Resolution Time" do
    test "performance exists and is an object", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               typeof performance === 'object' && typeof performance.now === 'function'
               """)
    end

    test "performance.now() returns a number", %{rt: rt} do
      assert {:ok, "number"} =
               QuickBEAM.eval(rt, "typeof performance.now()")
    end

    test "performance.now() returns a positive number", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "performance.now() > 0")
    end

    test "performance.now() difference is non-negative", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const now1 = performance.now();
               const now2 = performance.now();
               (now2 - now1) >= 0
               """)
    end

    test "performance.now() has reasonable magnitude vs Date", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 const hrt1 = performance.now();
                 const date1 = Date.now();
                 setTimeout(() => {
                   const hrt2 = performance.now();
                   const date2 = Date.now();
                   const hrtDiff = hrt2 - hrt1;
                   const dateDiff = date2 - date1;
                   resolve(Math.abs(hrtDiff - dateDiff) < 100);
                 }, 200);
               })
               """)
    end
  end
end
