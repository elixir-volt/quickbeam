defmodule QuickBEAM.WebAPIs.CompressionTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    {:ok, rt: rt}
  end

  describe "compression.compress/decompress" do
    test "gzip round-trip", %{rt: rt} do
      assert {:ok, "Hello, World!"} =
               QuickBEAM.eval(rt, """
               const data = new TextEncoder().encode('Hello, World!');
               const compressed = compression.compress('gzip', data);
               const decompressed = compression.decompress('gzip', compressed);
               new TextDecoder().decode(decompressed);
               """)
    end

    test "deflate round-trip", %{rt: rt} do
      assert {:ok, "Hello, World!"} =
               QuickBEAM.eval(rt, """
               const data = new TextEncoder().encode('Hello, World!');
               const compressed = compression.compress('deflate', data);
               const decompressed = compression.decompress('deflate', compressed);
               new TextDecoder().decode(decompressed);
               """)
    end

    test "deflate-raw round-trip", %{rt: rt} do
      assert {:ok, "Hello, World!"} =
               QuickBEAM.eval(rt, """
               const data = new TextEncoder().encode('Hello, World!');
               const compressed = compression.compress('deflate-raw', data);
               const decompressed = compression.decompress('deflate-raw', compressed);
               new TextDecoder().decode(decompressed);
               """)
    end

    test "gzip compresses data", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const input = 'A'.repeat(1000);
               const data = new TextEncoder().encode(input);
               const compressed = compression.compress('gzip', data);
               compressed.length < data.length;
               """)
    end

    test "returns Uint8Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const compressed = compression.compress('gzip', new TextEncoder().encode('test'));
               compressed instanceof Uint8Array;
               """)
    end

    test "string input accepted", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, """
               const compressed = compression.compress('gzip', 'hello');
               const decompressed = compression.decompress('gzip', compressed);
               new TextDecoder().decode(decompressed);
               """)
    end

    test "empty input", %{rt: rt} do
      assert {:ok, ""} =
               QuickBEAM.eval(rt, """
               const compressed = compression.compress('gzip', new Uint8Array());
               const decompressed = compression.decompress('gzip', compressed);
               new TextDecoder().decode(decompressed);
               """)
    end

    test "invalid format throws TypeError", %{rt: rt} do
      assert {:error, _} =
               QuickBEAM.eval(rt, "compression.compress('brotli', new Uint8Array([1]))")
    end

    test "binary data round-trip", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const data = new Uint8Array(256);
               for (let i = 0; i < 256; i++) data[i] = i;
               const compressed = compression.compress('gzip', data);
               const decompressed = compression.decompress('gzip', compressed);
               decompressed.length === 256 && decompressed.every((b, i) => b === i);
               """)
    end
  end
end
