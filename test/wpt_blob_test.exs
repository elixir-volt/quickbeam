defmodule QuickBEAM.WPT.BlobTest do
  @moduledoc "Ported from WPT: Blob-constructor.any.js, Blob-slice.any.js, Blob-array-buffer.any.js, Blob-bytes.any.js"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> if Process.alive?(rt), do: QuickBEAM.stop(rt) end)
    %{rt: rt}
  end

  # ── Blob constructor (Blob-constructor.any.js) ──

  describe "Blob constructor" do
    test "no arguments", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const b = new Blob();
               b instanceof Blob && b.size === 0 && b.type === ""
               """)
    end

    test "undefined first argument", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const b = new Blob(undefined);
               b instanceof Blob && b.size === 0 && b.type === ""
               """)
    end

    test "string array", %{rt: rt} do
      assert {:ok, "PASS"} =
               QuickBEAM.eval(rt, "await new Blob(['PASS']).text()")
    end

    test "ArrayBuffer element", %{rt: rt} do
      assert {:ok, 8} =
               QuickBEAM.eval(rt, "new Blob([new ArrayBuffer(8)]).size")
    end

    test "Uint8Array element", %{rt: rt} do
      assert {:ok, "PASS"} =
               QuickBEAM.eval(rt, """
               await new Blob([new Uint8Array([0x50, 0x41, 0x53, 0x53])]).text()
               """)
    end

    test "multiple blob parts", %{rt: rt} do
      assert {:ok, "foofoo"} =
               QuickBEAM.eval(rt, """
               const b = new Blob(['foo']);
               await new Blob([b, b]).text()
               """)
    end

    test "type option lowercased", %{rt: rt} do
      for {input, expected} <- [
            {"''", ""},
            {"'text/html'", "text/html"},
            {"'TEXT/HTML'", "text/html"},
            {"'text/plain;charset=utf-8'", "text/plain;charset=utf-8"}
          ] do
        assert {:ok, ^expected} =
                 QuickBEAM.eval(rt, "new Blob([], {type: #{input}}).type")
      end
    end

    test "invalid type characters produce empty type", %{rt: rt} do
      for type <- ["'\\u00E5'", "'\\t'", "'\\x7f'", "'\\0'"] do
        assert {:ok, ""} =
                 QuickBEAM.eval(rt, "new Blob([], {type: #{type}}).type")
      end
    end
  end

  # ── Blob.slice (Blob-slice.any.js) ──

  describe "Blob.slice" do
    test "no-argument slice", %{rt: rt} do
      assert {:ok, "PASS"} =
               QuickBEAM.eval(rt, "await new Blob(['PASS']).slice().text()")
    end

    test "negative start", %{rt: rt} do
      assert {:ok, "STRING"} =
               QuickBEAM.eval(rt, "await new Blob(['PASSSTRING']).slice(-6).text()")
    end

    test "start beyond length", %{rt: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, "await new Blob(['PASSSTRING']).slice(12).text()")
    end

    test "negative end", %{rt: rt} do
      assert {:ok, "PASS"} =
               QuickBEAM.eval(rt, "await new Blob(['PASSSTRING']).slice(0, -6).text()")
    end

    test "end before start produces empty", %{rt: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, "await new Blob(['PASSSTRING']).slice(7, 4).text()")
    end

    test "end beyond length", %{rt: rt} do
      assert {:ok, "PASSSTRING"} =
               QuickBEAM.eval(rt, "await new Blob(['PASSSTRING']).slice(0, 12).text()")
    end

    test "three string parts slicing", %{rt: rt} do
      assert {:ok, "foobarbaz"} =
               QuickBEAM.eval(rt, "await new Blob(['foo', 'bar', 'baz']).slice(0, 9).text()")

      assert {:ok, "barbaz"} =
               QuickBEAM.eval(rt, "await new Blob(['foo', 'bar', 'baz']).slice(3, 9).text()")

      assert {:ok, "baz"} =
               QuickBEAM.eval(rt, "await new Blob(['foo', 'bar', 'baz']).slice(6, 9).text()")
    end

    test "slice content type", %{rt: rt} do
      assert {:ok, "content/type"} =
               QuickBEAM.eval(rt, """
               new Blob(['abcd']).slice(undefined, undefined, 'content/type').type
               """)
    end

    test "undefined type becomes empty", %{rt: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, "new Blob().slice(0, 0, undefined).type")
    end

    test "invalid slice type produces empty type", %{rt: rt} do
      for type <- ["'\\xFF'", "'te\\x09xt/plain'", "'te\\x00xt/plain'"] do
        assert {:ok, ""} =
                 QuickBEAM.eval(rt, "new Blob(['PASS']).slice(0, 4, #{type}).type")
      end
    end
  end

  # ── Blob.arrayBuffer (Blob-array-buffer.any.js) ──

  describe "Blob.arrayBuffer" do
    test "basic arrayBuffer", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const input = new TextEncoder().encode('PASS');
               const ab = await new Blob([input]).arrayBuffer();
               ab instanceof ArrayBuffer &&
                 new Uint8Array(ab).every((v, i) => v === input[i])
               """)
    end

    test "empty Blob arrayBuffer", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, """
               const ab = await new Blob([new Uint8Array()]).arrayBuffer();
               new Uint8Array(ab).length
               """)
    end

    test "non-ascii arrayBuffer", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const input = new TextEncoder().encode('\\u08B8\\u000a');
               const ab = await new Blob([input]).arrayBuffer();
               new Uint8Array(ab).every((v, i) => v === input[i])
               """)
    end

    test "concurrent arrayBuffer reads", %{rt: rt} do
      assert {:ok, 3} =
               QuickBEAM.eval(rt, """
               const input = new TextEncoder().encode('PASS');
               const blob = new Blob([input]);
               const results = await Promise.all([
                 blob.arrayBuffer(), blob.arrayBuffer(), blob.arrayBuffer()
               ]);
               results.filter(ab => ab instanceof ArrayBuffer).length
               """)
    end
  end

  # ── Blob.bytes (Blob-bytes.any.js) ──

  describe "Blob.bytes" do
    test "basic bytes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const input = new TextEncoder().encode('PASS');
               const bytes = await new Blob([input]).bytes();
               bytes instanceof Uint8Array &&
                 bytes.every((v, i) => v === input[i])
               """)
    end

    test "empty Blob bytes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const bytes = await new Blob([new Uint8Array()]).bytes();
               bytes instanceof Uint8Array && bytes.length === 0
               """)
    end

    test "non-unicode bytes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const input = new Uint8Array([8, 241, 48, 123, 151]);
               const bytes = await new Blob([input]).bytes();
               bytes.every((v, i) => v === input[i])
               """)
    end

    test "concurrent bytes reads", %{rt: rt} do
      assert {:ok, 3} =
               QuickBEAM.eval(rt, """
               const input = new TextEncoder().encode('PASS');
               const blob = new Blob([input]);
               const results = await Promise.all([
                 blob.bytes(), blob.bytes(), blob.bytes()
               ]);
               results.filter(u => u instanceof Uint8Array).length
               """)
    end
  end
end
