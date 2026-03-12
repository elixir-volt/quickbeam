defmodule QuickBEAM.WebAPIs.WritableStreamTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    {:ok, rt: rt}
  end

  describe "WritableStream" do
    test "basic write and close", %{rt: rt} do
      assert {:ok, "a,b,c"} =
               QuickBEAM.eval(rt, """
               const chunks = [];
               const ws = new WritableStream({
                 write(chunk) { chunks.push(chunk); }
               });
               const writer = ws.getWriter();
               await writer.write("a");
               await writer.write("b");
               await writer.write("c");
               await writer.close();
               chunks.join(",")
               """)
    end

    test "locked after getWriter", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const ws = new WritableStream();
               ws.getWriter();
               ws.locked
               """)
    end

    test "unlocked after releaseLock", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, """
               const ws = new WritableStream();
               const w = ws.getWriter();
               w.releaseLock();
               ws.locked
               """)
    end
  end

  describe "TransformStream" do
    test "basic transform", %{rt: rt} do
      assert {:ok, [2, 4, 6]} =
               QuickBEAM.eval(rt, """
               const ts = new TransformStream({
                 transform(chunk, controller) {
                   controller.enqueue(chunk * 2);
                 }
               });
               const writer = ts.writable.getWriter();
               const reader = ts.readable.getReader();
               writer.write(1);
               writer.write(2);
               writer.write(3);
               writer.close();
               const results = [];
               while (true) {
                 const { value, done } = await reader.read();
                 if (done) break;
                 results.push(value);
               }
               results
               """)
    end

    test "passthrough when no transform", %{rt: rt} do
      assert {:ok, ["a", "b"]} =
               QuickBEAM.eval(rt, """
               const ts = new TransformStream();
               const writer = ts.writable.getWriter();
               const reader = ts.readable.getReader();
               writer.write("a");
               writer.write("b");
               writer.close();
               const results = [];
               while (true) {
                 const { value, done } = await reader.read();
                 if (done) break;
                 results.push(value);
               }
               results
               """)
    end
  end

  describe "TextEncoderStream" do
    test "encodes strings to Uint8Arrays", %{rt: rt} do
      assert {:ok, [72, 105]} =
               QuickBEAM.eval(rt, """
               const ts = new TextEncoderStream();
               const writer = ts.writable.getWriter();
               const reader = ts.readable.getReader();
               writer.write("Hi");
               writer.close();
               const { value } = await reader.read();
               [...value]
               """)
    end
  end

  describe "TextDecoderStream" do
    test "decodes Uint8Arrays to strings", %{rt: rt} do
      assert {:ok, "Hi"} =
               QuickBEAM.eval(rt, """
               const ts = new TextDecoderStream();
               const writer = ts.writable.getWriter();
               const reader = ts.readable.getReader();
               writer.write(new Uint8Array([72, 105]));
               writer.close();
               const { value } = await reader.read();
               value
               """)
    end
  end

  describe "pipeThrough" do
    test "ReadableStream.pipeThrough a TransformStream", %{rt: rt} do
      assert {:ok, ["HELLO", "WORLD"]} =
               QuickBEAM.eval(rt, """
               const rs = new ReadableStream({
                 start(controller) {
                   controller.enqueue("hello");
                   controller.enqueue("world");
                   controller.close();
                 }
               });
               const upper = new TransformStream({
                 transform(chunk, ctrl) { ctrl.enqueue(chunk.toUpperCase()); }
               });
               const reader = rs.pipeThrough(upper).getReader();
               const results = [];
               while (true) {
                 const { value, done } = await reader.read();
                 if (done) break;
                 results.push(value);
               }
               results
               """)
    end
  end

  describe "pipeTo" do
    test "ReadableStream.pipeTo a WritableStream", %{rt: rt} do
      assert {:ok, [1, 2, 3]} =
               QuickBEAM.eval(rt, """
               const collected = [];
               const rs = new ReadableStream({
                 start(c) { c.enqueue(1); c.enqueue(2); c.enqueue(3); c.close(); }
               });
               const ws = new WritableStream({
                 write(chunk) { collected.push(chunk); }
               });
               await rs.pipeTo(ws);
               collected
               """)
    end
  end
end
