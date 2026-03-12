defmodule QuickBEAM.WPT.MessageChannelTest do
  @moduledoc "Ported from WPT: webmessaging/message-channels"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "MessageChannel basics" do
    test "MessageChannel creates two ports", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               mc.port1 !== undefined && mc.port2 !== undefined &&
                 mc.port1 !== mc.port2
               """)
    end

    test "ports are MessagePort instances", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               mc.port1.constructor.name === 'MessagePort' &&
                 mc.port2.constructor.name === 'MessagePort'
               """)
    end
  end

  describe "MessagePort messaging" do
    test "posting on port1 delivers to port2", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const result = await new Promise(resolve => {
                 mc.port2.onmessage = e => resolve(e.data);
                 mc.port1.postMessage("hello");
               });
               result
               """)
    end

    test "posting on port2 delivers to port1", %{rt: rt} do
      assert {:ok, "world"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const result = await new Promise(resolve => {
                 mc.port1.onmessage = e => resolve(e.data);
                 mc.port2.postMessage("world");
               });
               result
               """)
    end

    test "data is cloned, not same reference", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const original = { key: "value" };
               const result = await new Promise(resolve => {
                 mc.port2.onmessage = e => resolve(e.data);
                 mc.port1.postMessage(original);
               });
               result.key === "value" && result !== original
               """)
    end

    test "multiple messages delivered in order", %{rt: rt} do
      assert {:ok, "1,2,3"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const received = [];
               const done = new Promise(resolve => {
                 mc.port2.onmessage = e => {
                   received.push(e.data);
                   if (received.length === 3) resolve(received.join(","));
                 };
               });
               mc.port1.postMessage("1");
               mc.port1.postMessage("2");
               mc.port1.postMessage("3");
               await done
               """)
    end
  end

  describe "MessageEvent properties" do
    test "event has correct type and data", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const event = await new Promise(resolve => {
                 mc.port2.onmessage = e => resolve(e);
                 mc.port1.postMessage(42);
               });
               event.type === "message" && event.data === 42
               """)
    end

    test "event has origin property", %{rt: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const event = await new Promise(resolve => {
                 mc.port2.onmessage = e => resolve(e);
                 mc.port1.postMessage("test");
               });
               event.origin
               """)
    end
  end

  describe "close behavior" do
    test "close prevents receiving messages", %{rt: rt} do
      assert {:ok, "timeout"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               mc.port2.onmessage = e => {};
               mc.port2.close();
               mc.port1.postMessage("should not arrive");
               const result = await Promise.race([
                 new Promise(resolve => {
                   mc.port2.onmessage = e => resolve("received");
                 }),
                 new Promise(resolve => setTimeout(() => resolve("timeout"), 50))
               ]);
               result
               """)
    end

    test "posting after close is silently ignored", %{rt: rt} do
      assert {:ok, "ok"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               mc.port1.close();
               mc.port1.postMessage("ignored");
               "ok"
               """)
    end

    test "close on sender side, messages to closed port are lost", %{rt: rt} do
      assert {:ok, "timeout"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               mc.port2.onmessage = e => {};
               mc.port1.close();
               mc.port1.postMessage("lost");
               const result = await Promise.race([
                 new Promise(resolve => {
                   mc.port2.onmessage = e => resolve("received");
                 }),
                 new Promise(resolve => setTimeout(() => resolve("timeout"), 50))
               ]);
               result
               """)
    end
  end

  describe "start behavior" do
    test "onmessage enables implicit start", %{rt: rt} do
      assert {:ok, "delivered"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const result = await new Promise(resolve => {
                 mc.port2.onmessage = e => resolve("delivered");
                 mc.port1.postMessage("test");
               });
               result
               """)
    end

    test "addEventListener requires explicit start", %{rt: rt} do
      assert {:ok, "started"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const result = await new Promise(resolve => {
                 mc.port2.addEventListener("message", e => resolve("started"));
                 mc.port1.postMessage("test");
                 mc.port2.start();
               });
               result
               """)
    end

    test "addEventListener without start does not deliver", %{rt: rt} do
      assert {:ok, "timeout"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               let received = false;
               mc.port2.addEventListener("message", () => { received = true; });
               mc.port1.postMessage("test");
               await new Promise(resolve => setTimeout(resolve, 50));
               received ? "received" : "timeout"
               """)
    end

    test "messages queue before start, delivered after start", %{rt: rt} do
      assert {:ok, "a,b,c"} =
               QuickBEAM.eval(rt, """
               const mc = new MessageChannel();
               const received = [];
               mc.port2.addEventListener("message", e => received.push(e.data));
               mc.port1.postMessage("a");
               mc.port1.postMessage("b");
               mc.port1.postMessage("c");
               mc.port2.start();
               await new Promise(resolve => setTimeout(resolve, 50));
               received.join(",")
               """)
    end
  end
end
