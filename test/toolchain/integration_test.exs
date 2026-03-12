defmodule QuickBEAM.Toolchain.IntegrationTest do
  use ExUnit.Case

  describe "TCP echo server — JS protocol logic, BEAM I/O" do
    test "JS handles TCP data via Beam.onMessage" do
      sockets = %{}
      sockets_agent = Agent.start_link(fn -> sockets end) |> elem(1)

      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "tcp.send" => fn [socket_id, response] ->
              socket = Agent.get(sockets_agent, &Map.fetch!(&1, socket_id))
              :gen_tcp.send(socket, response)
            end
          }
        )

      # JS protocol handler: uppercase echo
      QuickBEAM.eval(rt, """
      Beam.onMessage((msg) => {
        if (msg.type === "tcp_data") {
          const response = msg.data.toUpperCase() + "\\n";
          Beam.callSync("tcp.send", msg.socket_id, response);
        }
      });
      """)

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)

      # Accept in a separate process, forward to JS via the runtime
      accept_task =
        Task.async(fn ->
          {:ok, server_sock} = :gen_tcp.accept(listen)
          socket_id = "sock_1"
          Agent.update(sockets_agent, &Map.put(&1, socket_id, server_sock))

          {:ok, data} = :gen_tcp.recv(server_sock, 0, 5000)

          QuickBEAM.send_message(rt, %{
            type: "tcp_data",
            data: data,
            socket_id: socket_id
          })

          # Wait for JS to process and send response
          Process.sleep(50)
        end)

      {:ok, client} = :gen_tcp.connect(~c"localhost", port, [:binary, active: false])
      :gen_tcp.send(client, "hello beam")
      Task.await(accept_task)

      {:ok, response} = :gen_tcp.recv(client, 0, 5000)
      assert response == "HELLO BEAM\n"

      :gen_tcp.close(client)
      :gen_tcp.close(listen)
      Agent.stop(sockets_agent)
      QuickBEAM.stop(rt)
    end
  end

  describe "inter-runtime communication" do
    test "two JS runtimes exchange messages through BEAM" do
      {:ok, sup} =
        Supervisor.start_link(
          [
            {QuickBEAM, name: :producer, id: :producer},
            {QuickBEAM, name: :consumer, id: :consumer}
          ],
          strategy: :one_for_one
        )

      # Consumer collects messages
      QuickBEAM.eval(:consumer, """
      globalThis.inbox = [];
      Beam.onMessage((msg) => {
        globalThis.inbox.push(msg);
      });
      """)

      # Producer sends to consumer's PID
      consumer_pid = Process.whereis(:consumer)

      QuickBEAM.eval(:producer, """
      globalThis.sendTo = null;
      Beam.onMessage((pid) => {
        globalThis.sendTo = pid;
      });
      """)

      QuickBEAM.send_message(:producer, consumer_pid)
      Process.sleep(30)

      QuickBEAM.eval(:producer, """
      for (let i = 0; i < 5; i++) {
        Beam.send(globalThis.sendTo, {seq: i, from: "producer"});
      }
      """)

      Process.sleep(50)
      {:ok, inbox} = QuickBEAM.eval(:consumer, "globalThis.inbox")

      assert length(inbox) == 5
      assert Enum.at(inbox, 0) == %{"seq" => 0, "from" => "producer"}
      assert Enum.at(inbox, 4) == %{"seq" => 4, "from" => "producer"}

      Supervisor.stop(sup)
    end
  end

  describe "JS as BEAM process — full lifecycle" do
    test "supervised JS runtime with handlers, messaging, and crash recovery" do
      counter = :counters.new(1, [:atomics])

      {:ok, sup} =
        Supervisor.start_link(
          [
            {QuickBEAM,
             name: :lifecycle_rt,
             handlers: %{
               "counter.increment" => fn [n] ->
                 :counters.add(counter, 1, n)
                 :counters.get(counter, 1)
               end,
               "counter.get" => fn _ ->
                 :counters.get(counter, 1)
               end
             }}
          ],
          strategy: :one_for_one
        )

      # JS uses BEAM atomics through handlers
      {:ok, result} =
        QuickBEAM.eval(:lifecycle_rt, """
        const val = await Beam.call("counter.increment", 10);
        val;
        """)

      assert result == 10

      # JS receives messages and calls back into BEAM
      QuickBEAM.eval(:lifecycle_rt, """
      Beam.onMessage(async (msg) => {
        if (msg.action === "increment") {
          await Beam.call("counter.increment", msg.amount);
        }
      });
      """)

      QuickBEAM.send_message(:lifecycle_rt, %{action: "increment", amount: 5})
      Process.sleep(50)

      {:ok, count} = QuickBEAM.eval(:lifecycle_rt, "await Beam.call('counter.get')")
      assert count == 15

      # Kill the runtime — supervisor restarts it
      pid_before = Process.whereis(:lifecycle_rt)
      Process.exit(pid_before, :kill)
      Process.sleep(100)

      pid_after = Process.whereis(:lifecycle_rt)
      assert pid_after != pid_before

      # State is fresh, but the BEAM counter survives (it's outside JS)
      {:ok, count} = QuickBEAM.eval(:lifecycle_rt, "await Beam.call('counter.get')")
      assert count == 15

      Supervisor.stop(sup)
    end
  end

  describe "bidirectional streaming — BEAM pushes, JS processes, BEAM receives" do
    test "real-time data pipeline" do
      test_pid = self()

      {:ok, rt} =
        QuickBEAM.start(
          handlers: %{
            "emit" => fn [event] ->
              send(test_pid, {:js_event, event})
              :ok
            end
          }
        )

      # JS: stateful stream processor with windowed aggregation
      QuickBEAM.eval(rt, """
      globalThis.buffer = [];
      globalThis.windowSize = 3;

      Beam.onMessage((msg) => {
        if (msg.type === "data_point") {
          globalThis.buffer.push(msg.value);

          if (globalThis.buffer.length >= globalThis.windowSize) {
            const avg = globalThis.buffer.reduce((a, b) => a + b, 0) / globalThis.buffer.length;
            Beam.callSync("emit", {
              type: "window_avg",
              avg: avg,
              count: globalThis.buffer.length
            });
            globalThis.buffer = [];
          }
        }
      });
      """)

      # BEAM pushes data points — send one at a time so JS processes sequentially
      for val <- [10, 20, 30, 40, 50, 60] do
        QuickBEAM.send_message(rt, %{type: "data_point", value: val})
        Process.sleep(10)
      end

      Process.sleep(50)

      # JS should have emitted 2 window averages: (10+20+30)/3=20, (40+50+60)/3=50
      assert_receive {:js_event, %{"type" => "window_avg", "avg" => 20, "count" => 3}}, 1000
      assert_receive {:js_event, %{"type" => "window_avg", "avg" => 50, "count" => 3}}, 1000

      QuickBEAM.stop(rt)
    end
  end

  describe "crypto + binary — real-world JS↔BEAM data processing" do
    test "JS hashes data using BEAM's :crypto, processes result" do
      {:ok, rt} = QuickBEAM.start()

      {:ok, result} =
        QuickBEAM.eval(rt, """
        const data = new TextEncoder().encode("hello world");
        const hash = await crypto.subtle.digest("SHA-256", data);
        const hashArray = new Uint8Array(hash);

        // Convert to hex string in JS
        const hex = Array.from(hashArray)
          .map(b => b.toString(16).padStart(2, '0'))
          .join('');
        hex;
        """)

      expected = :crypto.hash(:sha256, "hello world") |> Base.encode16(case: :lower)
      assert result == expected

      QuickBEAM.stop(rt)
    end
  end
end
