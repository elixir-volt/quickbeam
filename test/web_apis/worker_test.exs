defmodule QuickBEAM.WebAPIs.WorkerTest do
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

    {:ok, rt: rt}
  end

  test "Worker sends message back to parent", %{rt: rt} do
    assert {:ok, "hello from worker"} =
             QuickBEAM.eval(rt, """
             await new Promise((resolve) => {
               const w = new Worker(`self.postMessage("hello from worker")`);
               w.onmessage = (e) => resolve(e.data);
             })
             """)
  end

  test "Worker receives message from parent", %{rt: rt} do
    assert {:ok, "pong: ping"} =
             QuickBEAM.eval(rt, """
             await new Promise((resolve) => {
               const w = new Worker(`
                 self.onmessage = (e) => {
                   self.postMessage("pong: " + e.data);
                 };

                 self.postMessage("__ready__");
               `);

               w.onmessage = (e) => {
                 if (e.data === "__ready__") {
                   w.onmessage = (reply) => resolve(reply.data);
                   w.postMessage("ping");
                 }
               };
             })
             """)
  end

  test "Worker runs independently and can do computation", %{rt: rt} do
    assert {:ok, 55} =
             QuickBEAM.eval(rt, """
             await new Promise((resolve) => {
               const w = new Worker(`
                 let sum = 0;
                 for (let i = 1; i <= 10; i++) sum += i;
                 self.postMessage(sum);
               `);
               w.onmessage = (e) => resolve(e.data);
             })
             """)
  end

  test "Worker can be terminated", %{rt: rt} do
    assert {:ok, "terminated"} =
             QuickBEAM.eval(rt, """
             const w = new Worker(`
               setTimeout(() => self.postMessage("should not arrive"), 500);
             `);
             w.terminate();
             "terminated"
             """)
  end

  test "multiple Workers run concurrently", %{rt: rt} do
    assert {:ok, [1, 2, 3]} =
             QuickBEAM.eval(
               rt,
               """
               await new Promise((resolve) => {
                 const results = [];
                 let count = 0;
                 for (let i = 1; i <= 3; i++) {
                   const w = new Worker(`self.postMessage(${i})`);
                   w.onmessage = (e) => {
                     results.push(e.data);
                     count++;
                     if (count === 3) resolve(results.sort());
                   };
                 }
               })
               """,
               timeout: 5000
             )
  end
end
