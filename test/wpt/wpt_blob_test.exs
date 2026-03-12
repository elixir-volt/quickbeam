defmodule QuickBEAM.WPT.BlobTest do
  @moduledoc "Ported from WPT: Blob-constructor.any.js, Blob-slice.any.js, Blob-array-buffer.any.js, Blob-bytes.any.js"
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

    test "empty array produces size 0", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, "new Blob([]).size")
    end

    test "Blob from another Blob preserves data", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, """
               const a = new Blob(['hello']);
               const b = new Blob([a]);
               await b.text()
               """)
    end

    test "DataView as blob part", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const buf = new ArrayBuffer(4);
               new Uint8Array(buf).set([0x50, 0x41, 0x53, 0x53]);
               const dv = new DataView(buf);
               await new Blob([dv]).text() === 'PASS'
               """)
    end

    test "Int8Array as blob part", %{rt: rt} do
      assert {:ok, 4} =
               QuickBEAM.eval(rt, """
               new Blob([new Int8Array([1, 2, 3, 4])]).size
               """)
    end

    test "Float32Array as blob part", %{rt: rt} do
      assert {:ok, 8} =
               QuickBEAM.eval(rt, """
               new Blob([new Float32Array([1.0, 2.0])]).size
               """)
    end

    test "Float64Array as blob part", %{rt: rt} do
      assert {:ok, 16} =
               QuickBEAM.eval(rt, """
               new Blob([new Float64Array([1.0, 2.0])]).size
               """)
    end

    test "Int16Array as blob part", %{rt: rt} do
      assert {:ok, 4} =
               QuickBEAM.eval(rt, """
               new Blob([new Int16Array([1, 2])]).size
               """)
    end

    test "Uint16Array as blob part", %{rt: rt} do
      assert {:ok, 4} =
               QuickBEAM.eval(rt, """
               new Blob([new Uint16Array([1, 2])]).size
               """)
    end

    test "Int32Array as blob part", %{rt: rt} do
      assert {:ok, 8} =
               QuickBEAM.eval(rt, """
               new Blob([new Int32Array([1, 2])]).size
               """)
    end

    test "Uint32Array as blob part", %{rt: rt} do
      assert {:ok, 4} =
               QuickBEAM.eval(rt, """
               new Blob([new Uint32Array([1])]).size
               """)
    end

    test "ArrayBuffer with byteOffset via typed array view", %{rt: rt} do
      assert {:ok, "SS"} =
               QuickBEAM.eval(rt, """
               const buf = new ArrayBuffer(4);
               new Uint8Array(buf).set([0x50, 0x41, 0x53, 0x53]);
               const view = new Uint8Array(buf, 2);
               await new Blob([view]).text()
               """)
    end

    test "boolean/number parts call toString", %{rt: rt} do
      assert {:ok, "12"} =
               QuickBEAM.eval(rt, "await new Blob([12]).text()")
    end

    test "boolean part calls toString", %{rt: rt} do
      assert {:ok, "true"} =
               QuickBEAM.eval(rt, "await new Blob([true]).text()")
    end

    test "object part calls toString", %{rt: rt} do
      assert {:ok, "[object Object]"} =
               QuickBEAM.eval(rt, "await new Blob([{}]).text()")
    end

    test "null part calls toString", %{rt: rt} do
      assert {:ok, "null"} =
               QuickBEAM.eval(rt, "await new Blob([null]).text()")
    end

    test "endings: 'native' option", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const b = new Blob(['a\\nb'], {endings: 'native'});
               b.size >= 3
               """)
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

    test "NaN start treated as 0", %{rt: rt} do
      assert {:ok, "hel"} =
               QuickBEAM.eval(rt, "await new Blob(['hello']).slice(NaN, 3).text()")
    end

    test "Infinity end", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, "await new Blob(['hello']).slice(0, Infinity).text()")
    end

    test "-Infinity start", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, "await new Blob(['hello']).slice(-Infinity).text()")
    end

    test "float values truncated", %{rt: rt} do
      assert {:ok, "el"} =
               QuickBEAM.eval(rt, "await new Blob(['hello']).slice(1.7, 3.2).text()")
    end

    test "slice of a slice", %{rt: rt} do
      assert {:ok, "ll"} =
               QuickBEAM.eval(rt, """
               const b = new Blob(['hello world']);
               await b.slice(2, 7).slice(0, 2).text()
               """)
    end

    test "slice returns a new Blob", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const b = new Blob(['hello']);
               const s = b.slice();
               s !== b && s instanceof Blob
               """)
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

    test "bytes returns independent copy", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const blob = new Blob([new Uint8Array([1, 2, 3])]);
               const bytes = await blob.bytes();
               bytes[0] = 99;
               const bytes2 = await blob.bytes();
               bytes2[0] === 1
               """)
    end

    test "bytes on empty blob returns empty Uint8Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const bytes = await new Blob([]).bytes();
               bytes instanceof Uint8Array && bytes.length === 0
               """)
    end
  end
end
