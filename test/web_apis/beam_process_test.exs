defmodule QuickBEAM.WebAPIs.BeamProcessTest do
  use ExUnit.Case, async: true
  @moduletag :beam_web_apis

  setup do
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(mode: :beam)

    on_exit(fn ->
      try do
        QuickBEAM.stop(rt)
      catch
        :exit, _ -> :ok
      end
    end)

    %{rt: rt}
  end

  describe "Beam.self()" do
    test "returns the owner GenServer PID", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Beam.self()")
      assert is_pid(result)
      assert result == rt
    end
  end

  describe "Beam.onMessage" do
    test "receives messages from Elixir", %{rt: rt} do
      QuickBEAM.eval(rt, """
      globalThis.messages = [];
      Beam.onMessage((msg) => {
        globalThis.messages.push(msg);
      });
      """)

      QuickBEAM.send_message(rt, "hello")
      QuickBEAM.send_message(rt, 42)
      QuickBEAM.send_message(rt, %{key: "value"})
      Process.sleep(50)

      {:ok, messages} = QuickBEAM.eval(rt, "globalThis.messages")
      assert messages == ["hello", 42, %{"key" => "value"}]
    end

    test "replaces previous handler", %{rt: rt} do
      QuickBEAM.eval(rt, """
      globalThis.result = [];
      Beam.onMessage((msg) => { globalThis.result.push("first:" + msg); });
      """)

      QuickBEAM.send_message(rt, "a")
      Process.sleep(30)

      QuickBEAM.eval(rt, """
      Beam.onMessage((msg) => { globalThis.result.push("second:" + msg); });
      """)

      QuickBEAM.send_message(rt, "b")
      Process.sleep(30)

      {:ok, result} = QuickBEAM.eval(rt, "globalThis.result")
      assert result == ["first:a", "second:b"]
    end

    test "receives messages during await", _ctx do
      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "slow_call" => fn _ ->
              Process.sleep(100)
              "done"
            end
          }
        )

      QuickBEAM.eval(rt, """
      globalThis.received = [];
      Beam.onMessage((msg) => {
        globalThis.received.push(msg);
      });
      """)

      task =
        Task.async(fn ->
          QuickBEAM.eval(rt, """
          const result = await Beam.call("slow_call");
          result;
          """)
        end)

      Process.sleep(30)
      QuickBEAM.send_message(rt, "during_await")
      {:ok, result} = Task.await(task)
      assert result == "done"

      {:ok, received} = QuickBEAM.eval(rt, "globalThis.received")
      assert received == ["during_await"]

      QuickBEAM.stop(rt)
    end

    test "discards messages when no handler is set", %{rt: rt} do
      QuickBEAM.send_message(rt, "dropped")
      Process.sleep(30)
      {:ok, result} = QuickBEAM.eval(rt, "typeof globalThis.lastMessage")
      assert result == "undefined"
    end

    test "handler errors don't crash the runtime", %{rt: rt} do
      QuickBEAM.eval(rt, """
      Beam.onMessage((msg) => {
        throw new Error("handler error");
      });
      """)

      QuickBEAM.send_message(rt, "trigger_error")
      Process.sleep(30)

      {:ok, result} = QuickBEAM.eval(rt, "1 + 1")
      assert result == 2
    end

    test "requires a function argument", %{rt: rt} do
      {:error, error} = QuickBEAM.eval(rt, "Beam.onMessage('not a function')")
      assert error.message =~ "function"
    end
  end

  describe "Beam.send" do
    test "sends a message to a BEAM process", %{rt: rt} do
      QuickBEAM.eval(rt, """
      globalThis.targetPid = null;
      Beam.onMessage((msg) => {
        globalThis.targetPid = msg;
      });
      """)

      # Send our PID to the JS runtime
      QuickBEAM.send_message(rt, self())
      Process.sleep(30)

      # Now JS sends a message back to us
      QuickBEAM.eval(rt, "Beam.send(globalThis.targetPid, {from: 'js', value: 42})")

      assert_receive %{"from" => "js", "value" => 42}, 1000
    end

    test "sends complex data types", %{rt: rt} do
      QuickBEAM.eval(rt, """
      Beam.onMessage((pid) => {
        Beam.send(pid, [1, "hello", true, null, {nested: "value"}]);
      });
      """)

      QuickBEAM.send_message(rt, self())
      assert_receive [1, "hello", true, nil, %{"nested" => "value"}], 1000
    end

    test "requires pid and message arguments", %{rt: rt} do
      {:error, error} = QuickBEAM.eval(rt, "Beam.send()")
      assert error.message =~ "pid and a message"
    end

    test "throws on invalid PID", %{rt: rt} do
      {:error, error} = QuickBEAM.eval(rt, "Beam.send('not_a_pid', 'hello')")
      assert error.message =~ "PID"
    end
  end

  describe "Process.monitor" do
    test "callback fires when monitored process exits normally", %{rt: rt} do
      pid = spawn(fn -> Process.sleep(50) end)

      QuickBEAM.eval(rt, """
        globalThis.downFired = false;
        globalThis.downReason = null;
        Beam.onMessage((msg) => {
          if (msg.action === "monitor") {
            Beam.monitor(msg.pid, (reason) => {
              globalThis.downFired = true;
              globalThis.downReason = reason;
            });
          }
        });
      """)

      QuickBEAM.send_message(rt, %{action: "monitor", pid: pid})
      Process.sleep(200)

      assert {:ok, true} = QuickBEAM.eval(rt, "downFired")
      assert {:ok, "normal"} = QuickBEAM.eval(rt, "downReason")
    end

    test "callback fires with exit reason", %{rt: rt} do
      pid =
        spawn(fn ->
          Process.sleep(50)
          exit(:kaboom)
        end)

      QuickBEAM.eval(rt, """
        globalThis.downReason = null;
        Beam.onMessage((msg) => {
          Beam.monitor(msg, (reason) => {
            globalThis.downReason = reason;
          });
        });
      """)

      QuickBEAM.send_message(rt, pid)
      Process.sleep(500)

      assert {:ok, "kaboom"} = QuickBEAM.eval(rt, "downReason")
    end

    test "monitor returns a reference", %{rt: rt} do
      pid = spawn(fn -> Process.sleep(5000) end)

      QuickBEAM.eval(rt, """
        globalThis.monRef = null;
        Beam.onMessage((pid) => {
          globalThis.monRef = Beam.monitor(pid, () => {});
        });
      """)

      QuickBEAM.send_message(rt, pid)
      Process.sleep(50)

      {:ok, ref} = QuickBEAM.eval(rt, "monRef")
      assert is_reference(ref)
      Process.exit(pid, :kill)
    end

    test "demonitor cancels the callback", %{rt: rt} do
      pid = spawn(fn -> Process.sleep(100) end)

      QuickBEAM.eval(rt, """
        globalThis.downFired = false;
        Beam.onMessage((pid) => {
          const ref = Beam.monitor(pid, () => {
            globalThis.downFired = true;
          });
          Beam.demonitor(ref);
        });
      """)

      QuickBEAM.send_message(rt, pid)
      Process.sleep(250)

      assert {:ok, false} = QuickBEAM.eval(rt, "downFired")
    end

    test "multiple monitors on different processes", %{rt: rt} do
      pid1 = spawn(fn -> Process.sleep(50) end)
      pid2 = spawn(fn -> Process.sleep(100) end)

      QuickBEAM.eval(rt, """
        globalThis.downs = [];
        Beam.onMessage((msg) => {
          Beam.monitor(msg.pid, (reason) => {
            globalThis.downs.push(msg.name);
          });
        });
      """)

      QuickBEAM.send_message(rt, %{pid: pid1, name: "first"})
      QuickBEAM.send_message(rt, %{pid: pid2, name: "second"})
      Process.sleep(250)

      {:ok, downs} = QuickBEAM.eval(rt, "downs")
      assert "first" in downs
      assert "second" in downs
    end

    test "Beam.onMessage still works alongside monitors", %{rt: rt} do
      pid = spawn(fn -> Process.sleep(50) end)

      QuickBEAM.eval(rt, """
        globalThis.regularMessages = [];
        globalThis.downFired = false;
        Beam.onMessage((msg) => {
          if (typeof msg === "string") {
            globalThis.regularMessages.push(msg);
          } else {
            Beam.monitor(msg, () => { globalThis.downFired = true; });
          }
        });
      """)

      QuickBEAM.send_message(rt, "hello")
      QuickBEAM.send_message(rt, pid)
      QuickBEAM.send_message(rt, "world")
      Process.sleep(200)

      assert {:ok, ["hello", "world"]} = QuickBEAM.eval(rt, "regularMessages")
      assert {:ok, true} = QuickBEAM.eval(rt, "downFired")
    end
  end

  describe "PID round-trip" do
    test "PID survives Elixir→JS→Elixir conversion", %{rt: rt} do
      original_pid = self()

      {:ok, _} =
        QuickBEAM.start(
          handlers: %{
            "echo" => fn [val] -> val end
          }
        )

      QuickBEAM.eval(rt, """
      globalThis.storedPid = null;
      Beam.onMessage((msg) => {
        globalThis.storedPid = msg;
      });
      """)

      QuickBEAM.send_message(rt, original_pid)
      Process.sleep(30)

      {:ok, returned_pid} = QuickBEAM.eval(rt, "globalThis.storedPid")
      assert returned_pid == original_pid
    end
  end
end
