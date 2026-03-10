defmodule QuickBEAM.SerializationTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    %{rt: rt}
  end

  describe "JS → BEAM type mapping" do
    test "null and undefined → nil", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "null")
      assert {:ok, nil} = QuickBEAM.eval(rt, "undefined")
    end

    test "booleans", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "true")
      assert {:ok, false} = QuickBEAM.eval(rt, "false")
    end

    test "integers", %{rt: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, "42")
      assert {:ok, 0} = QuickBEAM.eval(rt, "0")
      assert {:ok, -1} = QuickBEAM.eval(rt, "-1")
      assert {:ok, 1_000_000} = QuickBEAM.eval(rt, "1000000")
    end

    test "floats", %{rt: rt} do
      assert {:ok, 3.14} = QuickBEAM.eval(rt, "3.14")
      assert {:ok, -0.5} = QuickBEAM.eval(rt, "-0.5")
    end

    test "float that looks like integer stays integer", %{rt: rt} do
      assert {:ok, 1} = QuickBEAM.eval(rt, "1.0")
    end

    test "Infinity and NaN as atoms", %{rt: rt} do
      assert {:ok, :Infinity} = QuickBEAM.eval(rt, "Infinity")
      assert {:ok, :"-Infinity"} = QuickBEAM.eval(rt, "-Infinity")
      assert {:ok, :NaN} = QuickBEAM.eval(rt, "NaN")
    end

    test "strings", %{rt: rt} do
      assert {:ok, "hello"} = QuickBEAM.eval(rt, "'hello'")
      assert {:ok, ""} = QuickBEAM.eval(rt, "''")
      assert {:ok, "héllo"} = QuickBEAM.eval(rt, "'héllo'")
      assert {:ok, "日本語"} = QuickBEAM.eval(rt, "'日本語'")
    end

    test "Uint8Array → binary", %{rt: rt} do
      assert {:ok, <<1, 2, 3>>} = QuickBEAM.eval(rt, "new Uint8Array([1, 2, 3])")
    end

    test "empty Uint8Array → empty binary", %{rt: rt} do
      assert {:ok, <<>>} = QuickBEAM.eval(rt, "new Uint8Array()")
    end

    test "Uint8Array from ArrayBuffer", %{rt: rt} do
      assert {:ok, <<0, 0, 0, 0>>} = QuickBEAM.eval(rt, "new Uint8Array(new ArrayBuffer(4))")
    end

    test "ArrayBuffer → binary", %{rt: rt} do
      assert {:ok, <<0, 0, 0, 0, 0, 0, 0, 0>>} = QuickBEAM.eval(rt, "new ArrayBuffer(8)")
    end

    test "Uint8Array with values", %{rt: rt} do
      assert {:ok, <<255, 0, 128>>} = QuickBEAM.eval(rt, "new Uint8Array([255, 0, 128])")
    end

    test "Uint8Array slice (subarray)", %{rt: rt} do
      assert {:ok, <<2, 3>>} =
               QuickBEAM.eval(rt, "new Uint8Array([1, 2, 3, 4]).subarray(1, 3)")
    end

    test "Int32Array → binary", %{rt: rt} do
      {:ok, bin} = QuickBEAM.eval(rt, "new Int32Array([1, 2])")
      assert is_binary(bin)
      assert byte_size(bin) == 8
    end

    test "arrays → lists", %{rt: rt} do
      assert {:ok, [1, 2, 3]} = QuickBEAM.eval(rt, "[1, 2, 3]")
      assert {:ok, []} = QuickBEAM.eval(rt, "[]")
    end

    test "nested arrays", %{rt: rt} do
      assert {:ok, [1, [2, 3], 4]} = QuickBEAM.eval(rt, "[1, [2, 3], 4]")
    end

    test "arrays with mixed types", %{rt: rt} do
      assert {:ok, [1, "two", true, nil]} = QuickBEAM.eval(rt, "[1, 'two', true, null]")
    end

    test "objects → maps", %{rt: rt} do
      assert {:ok, %{"a" => 1, "b" => 2}} = QuickBEAM.eval(rt, "({a: 1, b: 2})")
    end

    test "empty object", %{rt: rt} do
      assert {:ok, %{}} = QuickBEAM.eval(rt, "({})")
    end

    test "nested objects", %{rt: rt} do
      assert {:ok, %{"a" => %{"b" => 1}}} = QuickBEAM.eval(rt, "({a: {b: 1}})")
    end

    test "object with array values", %{rt: rt} do
      assert {:ok, %{"items" => [1, 2, 3]}} = QuickBEAM.eval(rt, "({items: [1, 2, 3]})")
    end

    test "TextEncoder returns binary", %{rt: rt} do
      assert {:ok, bin} = QuickBEAM.eval(rt, "new TextEncoder().encode('hello')")
      assert bin == "hello"
    end
  end

  describe "large binaries" do
    test "1MB Uint8Array", %{rt: rt} do
      assert {:ok, bin} =
               QuickBEAM.eval(rt, "new Uint8Array(1024 * 1024).fill(42)")

      assert byte_size(bin) == 1024 * 1024
      assert :binary.first(bin) == 42
    end
  end

  describe "beam.call roundtrip" do
    setup do
      handlers = %{
        "echo" => fn [val] -> val end,
        "double" => fn [n] -> n * 2 end
      }

      {:ok, rt} = QuickBEAM.start(handlers: handlers)
      %{rt: rt}
    end

    test "string roundtrip through beam.call", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, "await beam.call('echo', 'hello')")
    end

    test "number roundtrip through beam.call", %{rt: rt} do
      assert {:ok, 84} =
               QuickBEAM.eval(rt, "await beam.call('double', 42)")
    end

    test "object roundtrip through beam.call", %{rt: rt} do
      assert {:ok, %{"a" => 1}} =
               QuickBEAM.eval(rt, "await beam.call('echo', {a: 1})")
    end
  end
end
