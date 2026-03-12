defmodule QuickBEAM.WebAPIs.MessageChannelTest do
  @moduledoc "Merged from WPT: webmessaging/message-channels + additional coverage"
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

    %{rt: rt}
  end

  describe "MessageChannel" do
    test "port1 and port2 exist", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               ch.port1 instanceof MessagePort && ch.port2 instanceof MessagePort;
               """)
    end

    test "basic message passing via onmessage", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               let received;
               ch.port2.onmessage = (e) => { received = e.data; };
               ch.port1.postMessage('hello');
               await new Promise(resolve => queueMicrotask(resolve));
               received;
               """)
    end

    test "bidirectional communication", %{rt: rt} do
      assert {:ok, ["from1", "from2"]} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               const results = [];
               ch.port1.onmessage = (e) => { results.push(e.data); };
               ch.port2.onmessage = (e) => { results.push(e.data); };
               ch.port1.postMessage('from1');
               ch.port2.postMessage('from2');
               await new Promise(resolve => queueMicrotask(resolve));
               results;
               """)
    end

    test "close prevents further messages", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               let count = 0;
               ch.port2.onmessage = () => { count++; };
               ch.port2.close();
               ch.port1.postMessage('ignored');
               await new Promise(resolve => queueMicrotask(resolve));
               count;
               """)
    end

    test "close on sender side prevents messages", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               let count = 0;
               ch.port2.onmessage = () => { count++; };
               ch.port1.close();
               ch.port1.postMessage('ignored');
               await new Promise(resolve => queueMicrotask(resolve));
               count;
               """)
    end

    test "onmessage setter auto-starts the port", %{rt: rt} do
      assert {:ok, "started"} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               ch.port1.postMessage('started');
               let received;
               ch.port2.onmessage = (e) => { received = e.data; };
               await new Promise(resolve => queueMicrotask(resolve));
               received;
               """)
    end

    test "queued messages delivered after start", %{rt: rt} do
      assert {:ok, ["a", "b", "c"]} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               const msgs = [];
               ch.port2.addEventListener('message', (e) => { msgs.push(e.data); });
               ch.port1.postMessage('a');
               ch.port1.postMessage('b');
               ch.port1.postMessage('c');
               await new Promise(resolve => queueMicrotask(resolve));
               ch.port2.start();
               await new Promise(resolve => queueMicrotask(resolve));
               msgs;
               """)
    end

    test "MessageEvent has correct data property", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               let event;
               ch.port2.onmessage = (e) => { event = e; };
               ch.port1.postMessage({ key: 'value' });
               await new Promise(resolve => queueMicrotask(resolve));
               event instanceof MessageEvent && event.type === 'message' && event.data.key === 'value';
               """)
    end

    test "multiple messages in sequence", %{rt: rt} do
      assert {:ok, [1, 2, 3]} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               const received = [];
               ch.port2.onmessage = (e) => { received.push(e.data); };
               ch.port1.postMessage(1);
               ch.port1.postMessage(2);
               ch.port1.postMessage(3);
               await new Promise(resolve => queueMicrotask(resolve));
               received;
               """)
    end
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

    test "messages are async", %{rt: rt} do
      assert {:ok, ["post", "received"]} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               const order = [];
               ch.port2.onmessage = () => { order.push('received'); };
               ch.port1.postMessage('x');
               order.push('post');
               await new Promise(resolve => queueMicrotask(resolve));
               order;
               """)
    end

    test "structuredClone semantics", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               const original = { nested: { value: 42 } };
               let cloned;
               ch.port2.onmessage = (e) => { cloned = e.data; };
               ch.port1.postMessage(original);
               await new Promise(resolve => queueMicrotask(resolve));
               cloned.nested.value === 42 && cloned !== original && cloned.nested !== original.nested;
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

    test "onmessageerror is settable", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               ch.port1.onmessageerror = () => {};
               typeof ch.port1.onmessageerror === 'function';
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
