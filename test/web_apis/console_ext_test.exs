defmodule QuickBEAM.WebAPIs.ConsoleExtTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  setup do
    {:ok, rt} = QuickBEAM.start()
    {:ok, rt: rt}
  end

  test "console.debug routes to Logger info", %{rt: rt} do
    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, ~s[console.debug("debug msg")])
        Process.sleep(50)
      end)

    assert log =~ "debug msg"
  end

  test "console.assert does nothing on true", %{rt: rt} do
    log =
      capture_log([level: :error], fn ->
        QuickBEAM.eval(rt, ~s[console.assert(true, "should not appear")])
        Process.sleep(50)
      end)

    refute log =~ "should not appear"
  end

  test "console.assert logs on false", %{rt: rt} do
    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, ~s[console.assert(false, "failed!")])
        Process.sleep(50)
      end)

    assert log =~ "Assertion failed:"
    assert log =~ "failed!"
  end

  test "console.time and console.timeEnd", %{rt: rt} do
    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, """
        console.time("op");
        let s = 0; for (let i = 0; i < 1000; i++) s += i;
        console.timeEnd("op");
        """)

        Process.sleep(50)
      end)

    assert log =~ "op:"
    assert log =~ "ms"
  end

  test "console.count increments", %{rt: rt} do
    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, """
        console.count("hits");
        console.count("hits");
        console.count("hits");
        """)

        Process.sleep(50)
      end)

    assert log =~ "hits: 1"
    assert log =~ "hits: 2"
    assert log =~ "hits: 3"
  end

  test "console.dir serializes object", %{rt: rt} do
    log =
      capture_log(fn ->
        QuickBEAM.eval(rt, ~s[console.dir({a: 1, b: 2})])
        Process.sleep(50)
      end)

    assert log =~ "\"a\": 1"
    assert log =~ "\"b\": 2"
  end
end
