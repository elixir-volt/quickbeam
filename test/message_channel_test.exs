defmodule QuickBEAM.MessageChannelTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
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

    test "addEventListener requires explicit start", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               let received = false;
               ch.port2.addEventListener('message', () => { received = true; });
               ch.port1.postMessage('test');
               await new Promise(resolve => queueMicrotask(resolve));
               const beforeStart = received;
               ch.port2.start();
               await new Promise(resolve => queueMicrotask(resolve));
               const afterStart = received;
               !beforeStart && afterStart;
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

    test "onmessageerror is settable", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ch = new MessageChannel();
               ch.port1.onmessageerror = () => {};
               typeof ch.port1.onmessageerror === 'function';
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
end
