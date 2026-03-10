defmodule QuickBEAM.NewWebAPIsTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    {:ok, rt: rt}
  end

  defp await_condition(fun, retries \\ 50) do
    result = fun.()

    if result do
      result
    else
      if retries > 0 do
        Process.sleep(50)
        await_condition(fun, retries - 1)
      else
        result
      end
    end
  end

  # ── crypto.randomUUID ────────────────────────────────────

  describe "crypto.randomUUID" do
    test "returns a valid UUID v4 string", %{rt: rt} do
      {:ok, uuid} = QuickBEAM.eval(rt, "crypto.randomUUID()")
      assert uuid =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
    end

    test "returns unique values", %{rt: rt} do
      {:ok, a} = QuickBEAM.eval(rt, "crypto.randomUUID()")
      {:ok, b} = QuickBEAM.eval(rt, "crypto.randomUUID()")
      assert a != b
    end

    test "is a function", %{rt: rt} do
      assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof crypto.randomUUID")
    end
  end

  # ── Event / EventTarget ──────────────────────────────────

  describe "EventTarget" do
    test "addEventListener and dispatchEvent", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const target = new EventTarget();
               let called = false;
               target.addEventListener('test', () => { called = true; });
               target.dispatchEvent(new Event('test'));
               called;
               """)
    end

    test "removeEventListener", %{rt: rt} do
      assert {:ok, 1} =
               QuickBEAM.eval(rt, """
               const target = new EventTarget();
               let count = 0;
               const handler = () => { count++; };
               target.addEventListener('test', handler);
               target.dispatchEvent(new Event('test'));
               target.removeEventListener('test', handler);
               target.dispatchEvent(new Event('test'));
               count;
               """)
    end

    test "once option", %{rt: rt} do
      assert {:ok, 1} =
               QuickBEAM.eval(rt, """
               const target = new EventTarget();
               let count = 0;
               target.addEventListener('test', () => { count++; }, { once: true });
               target.dispatchEvent(new Event('test'));
               target.dispatchEvent(new Event('test'));
               count;
               """)
    end

    test "multiple listeners fire in order", %{rt: rt} do
      assert {:ok, [1, 2, 3]} =
               QuickBEAM.eval(rt, """
               const target = new EventTarget();
               const order = [];
               target.addEventListener('test', () => order.push(1));
               target.addEventListener('test', () => order.push(2));
               target.addEventListener('test', () => order.push(3));
               target.dispatchEvent(new Event('test'));
               order;
               """)
    end

    test "stopImmediatePropagation", %{rt: rt} do
      assert {:ok, [1]} =
               QuickBEAM.eval(rt, """
               const target = new EventTarget();
               const order = [];
               target.addEventListener('test', (e) => { order.push(1); e.stopImmediatePropagation(); });
               target.addEventListener('test', () => order.push(2));
               target.dispatchEvent(new Event('test'));
               order;
               """)
    end
  end

  # ── DOMException ─────────────────────────────────────────

  describe "DOMException" do
    test "has name and message", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const e = new DOMException('test message', 'AbortError');
               e.name === 'AbortError' && e.message === 'test message' && e instanceof Error;
               """)
    end
  end

  # ── AbortController / AbortSignal ────────────────────────

  describe "AbortController" do
    test "signal starts not aborted", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, "new AbortController().signal.aborted")
    end

    test "abort sets aborted and reason", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ac = new AbortController();
               ac.abort();
               ac.signal.aborted && ac.signal.reason instanceof DOMException;
               """)
    end

    test "abort fires event listener", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ac = new AbortController();
               let fired = false;
               ac.signal.addEventListener('abort', () => { fired = true; });
               ac.abort();
               fired;
               """)
    end

    test "AbortSignal.abort() creates pre-aborted signal", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "AbortSignal.abort().aborted")
    end

    test "AbortSignal.timeout() aborts after ms", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const signal = AbortSignal.timeout(10);
               await new Promise(resolve => setTimeout(resolve, 30));
               signal.aborted && signal.reason instanceof DOMException && signal.reason.name === 'TimeoutError';
               """)
    end

    test "throwIfAborted throws when aborted", %{rt: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, """
               const signal = AbortSignal.abort();
               signal.throwIfAborted();
               """)
    end

    test "AbortSignal.any()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ac1 = new AbortController();
               const ac2 = new AbortController();
               const combined = AbortSignal.any([ac1.signal, ac2.signal]);
               ac2.abort('reason2');
               combined.aborted && combined.reason === 'reason2';
               """)
    end
  end

  # ── Blob ─────────────────────────────────────────────────

  describe "Blob" do
    test "size and type", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const blob = new Blob(['hello'], { type: 'text/plain' });
               blob.size === 5 && blob.type === 'text/plain';
               """)
    end

    test "text()", %{rt: rt} do
      assert {:ok, "hello world"} =
               QuickBEAM.eval(rt, """
               const blob = new Blob(['hello', ' ', 'world']);
               await blob.text();
               """)
    end

    test "arrayBuffer()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const blob = new Blob(['AB']);
               const buf = await blob.arrayBuffer();
               buf instanceof ArrayBuffer && new Uint8Array(buf)[0] === 65;
               """)
    end

    test "slice()", %{rt: rt} do
      assert {:ok, "ell"} =
               QuickBEAM.eval(rt, """
               const blob = new Blob(['hello']);
               const sliced = blob.slice(1, 4);
               await sliced.text();
               """)
    end

    test "empty blob", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const blob = new Blob();
               blob.size === 0 && blob.type === '';
               """)
    end

    test "Uint8Array parts", %{rt: rt} do
      assert {:ok, 3} =
               QuickBEAM.eval(rt, """
               const blob = new Blob([new Uint8Array([1, 2, 3])]);
               blob.size;
               """)
    end
  end

  # ── File ─────────────────────────────────────────────────

  describe "File" do
    test "has name and lastModified", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const file = new File(['content'], 'test.txt', { type: 'text/plain' });
               file.name === 'test.txt' && typeof file.lastModified === 'number' && file.size === 7;
               """)
    end
  end

  # ── Headers ──────────────────────────────────────────────

  describe "Headers" do
    test "case-insensitive get", %{rt: rt} do
      assert {:ok, "bar"} =
               QuickBEAM.eval(rt, """
               const h = new Headers([['Foo', 'bar']]);
               h.get('foo');
               """)
    end

    test "append joins with comma", %{rt: rt} do
      assert {:ok, "a, b"} =
               QuickBEAM.eval(rt, """
               const h = new Headers();
               h.append('x', 'a');
               h.append('x', 'b');
               h.get('x');
               """)
    end

    test "set replaces", %{rt: rt} do
      assert {:ok, "new"} =
               QuickBEAM.eval(rt, """
               const h = new Headers([['x', 'old']]);
               h.set('x', 'new');
               h.get('x');
               """)
    end

    test "has/delete", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const h = new Headers([['x', 'y']]);
               const had = h.has('x');
               h.delete('x');
               had && !h.has('x');
               """)
    end

    test "entries are sorted", %{rt: rt} do
      assert {:ok, ["a", "b", "c"]} =
               QuickBEAM.eval(rt, """
               const h = new Headers([['c', '3'], ['a', '1'], ['b', '2']]);
               [...h.keys()];
               """)
    end

    test "construct from object", %{rt: rt} do
      assert {:ok, "val"} =
               QuickBEAM.eval(rt, """
               const h = new Headers({ key: 'val' });
               h.get('key');
               """)
    end
  end

  # ── ReadableStream ───────────────────────────────────────

  describe "ReadableStream" do
    test "read chunks from stream", %{rt: rt} do
      assert {:ok, [1, 2, 3]} =
               QuickBEAM.eval(rt, """
               const stream = new ReadableStream({
                 start(controller) {
                   controller.enqueue(1);
                   controller.enqueue(2);
                   controller.enqueue(3);
                   controller.close();
                 }
               });
               const reader = stream.getReader();
               const results = [];
               while (true) {
                 const { value, done } = await reader.read();
                 if (done) break;
                 results.push(value);
               }
               results;
               """)
    end

    test "locked after getReader", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const stream = new ReadableStream();
               stream.getReader();
               stream.locked;
               """)
    end

    test "async iterator", %{rt: rt} do
      assert {:ok, [10, 20]} =
               QuickBEAM.eval(rt, """
               const stream = new ReadableStream({
                 start(controller) {
                   controller.enqueue(10);
                   controller.enqueue(20);
                   controller.close();
                 }
               });
               const items = [];
               for await (const chunk of stream) items.push(chunk);
               items;
               """)
    end
  end

  # ── Request ──────────────────────────────────────────────

  describe "Request" do
    test "basic construction", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const req = new Request('https://example.com', { method: 'POST' });
               req.url === 'https://example.com' && req.method === 'POST';
               """)
    end

    test "defaults to GET", %{rt: rt} do
      assert {:ok, "GET"} =
               QuickBEAM.eval(rt, "new Request('https://example.com').method")
    end

    test "clone", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const req = new Request('https://example.com', { method: 'PUT' });
               const clone = req.clone();
               clone.url === req.url && clone.method === 'PUT' && clone !== req;
               """)
    end
  end

  # ── Response ─────────────────────────────────────────────

  describe "Response" do
    test "Response.json()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const res = Response.json({ foo: 'bar' });
               res.status === 200 && res.headers.get('content-type') === 'application/json';
               """)
    end

    test "Response.redirect()", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const res = Response.redirect('https://example.com', 301);
               res.status === 301 && res.headers.get('location') === 'https://example.com';
               """)
    end
  end

  # ── BroadcastChannel ─────────────────────────────────────

  describe "BroadcastChannel" do
    test "messages between two runtimes", _context do
      {:ok, rt1} = QuickBEAM.start()
      {:ok, rt2} = QuickBEAM.start()

      QuickBEAM.eval(rt1, """
      globalThis.__received = [];
      const ch = new BroadcastChannel('test-chan');
      ch.onmessage = (e) => { globalThis.__received.push(e.data); };
      """)

      Process.sleep(100)

      QuickBEAM.eval(rt2, """
      const ch = new BroadcastChannel('test-chan');
      ch.postMessage('hello from rt2');
      """)

      assert await_condition(fn ->
               {:ok, ["hello from rt2"]} == QuickBEAM.eval(rt1, "globalThis.__received")
             end)
    end
  end
end
