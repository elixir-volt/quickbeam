defmodule QuickBEAM.DOM.MutationObserverTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, runtime} = QuickBEAM.start()

    on_exit(fn ->
      try do
        QuickBEAM.stop(runtime)
      catch
        :exit, _ -> :ok
      end
    end)

    %{runtime: runtime}
  end

  test "MutationObserver is defined", %{runtime: rt} do
    assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof MutationObserver")
  end

  test "observe does not throw", %{runtime: rt} do
    assert {:ok, nil} =
             QuickBEAM.eval(rt, """
             const observer = new MutationObserver(() => {})
             observer.observe(document.body, { childList: true })
             undefined
             """)
  end

  test "disconnect does not throw", %{runtime: rt} do
    assert {:ok, nil} =
             QuickBEAM.eval(rt, """
             const observer = new MutationObserver(() => {})
             observer.observe(document.body)
             observer.disconnect()
             undefined
             """)
  end

  test "takeRecords returns empty array", %{runtime: rt} do
    assert {:ok, 0} =
             QuickBEAM.eval(rt, """
             const observer = new MutationObserver(() => {})
             observer.observe(document.body, { childList: true })
             observer.takeRecords().length
             """)
  end
end
