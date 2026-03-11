defmodule QuickBEAM.LocksTest do
  use ExUnit.Case, async: false

  setup do
    start_supervised!(QuickBEAM.LockManager)
    {:ok, rt} = QuickBEAM.start()

    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)

    {:ok, rt: rt}
  end

  describe "navigator.locks.request" do
    test "exclusive lock runs callback and returns result", %{rt: rt} do
      assert {:ok, "locked!"} =
               QuickBEAM.eval(rt, """
               await navigator.locks.request("test1", async (lock) => {
                 return "locked!";
               })
               """)
    end

    test "lock object has name and mode", %{rt: rt} do
      assert {:ok, %{"name" => "res1", "mode" => "exclusive"}} =
               QuickBEAM.eval(rt, """
               await navigator.locks.request("res1", async (lock) => {
                 return { name: lock.name, mode: lock.mode };
               })
               """)
    end

    test "shared mode lock", %{rt: rt} do
      assert {:ok, "shared"} =
               QuickBEAM.eval(rt, """
               await navigator.locks.request("res2", { mode: "shared" }, async (lock) => {
                 return lock.mode;
               })
               """)
    end

    test "ifAvailable returns null when lock is held", %{rt: rt} do
      assert {:ok, "got null"} =
               QuickBEAM.eval(rt, """
               await navigator.locks.request("busy", async (lock) => {
                 const inner = await navigator.locks.request("busy", { ifAvailable: true }, async (lock2) => {
                   return lock2 === null ? "got null" : "got lock";
                 });
                 return inner;
               })
               """)
    end

    test "lock is released after callback completes", %{rt: rt} do
      assert {:ok, "second"} =
               QuickBEAM.eval(rt, """
               await navigator.locks.request("rel", async () => "first");
               await navigator.locks.request("rel", async () => "second");
               """)
    end
  end

  describe "navigator.locks.query" do
    test "shows held locks", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               await navigator.locks.request("querytest", async (lock) => {
                 const state = await navigator.locks.query();
                 return state.held.some(l => l.name === "querytest" && l.mode === "exclusive");
               })
               """)
    end

    test "empty when no locks held", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
               const state = await navigator.locks.query();
               state.held.length
               """)
    end
  end

  describe "cross-runtime locking" do
    test "exclusive lock blocks second runtime", context do
      {:ok, rt2} = QuickBEAM.start()

      on_exit(fn -> try do QuickBEAM.stop(rt2) catch :exit, _ -> :ok end end)

      rt1 = context.rt

      # rt1 grabs lock, rt2 tries ifAvailable and fails
      {:ok, _} =
        QuickBEAM.eval(rt1, """
        globalThis.lockPromise = navigator.locks.request("shared_res", async (lock) => {
          await new Promise(r => setTimeout(r, 500));
          return "done";
        });
        "holding"
        """)

      Process.sleep(50)

      assert {:ok, "not_available"} =
               QuickBEAM.eval(rt2, """
               await navigator.locks.request("shared_res", { ifAvailable: true }, async (lock) => {
                 return lock === null ? "not_available" : "available";
               })
               """)
    end
  end
end
