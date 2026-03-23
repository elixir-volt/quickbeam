defmodule QuickBEAM.Core.SerializationTest do
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

    test "Symbol → atom", %{rt: rt} do
      assert {:ok, :hello} = QuickBEAM.eval(rt, "Symbol('hello')")
    end

    test "Symbol.for → atom", %{rt: rt} do
      assert {:ok, :global_sym} = QuickBEAM.eval(rt, "Symbol.for('global_sym')")
    end

    test "well-known Symbol → atom", %{rt: rt} do
      assert {:ok, :"Symbol.iterator"} = QuickBEAM.eval(rt, "Symbol.iterator")
    end

    test "Symbol without description", %{rt: rt} do
      assert {:ok, :symbol} = QuickBEAM.eval(rt, "Symbol()")
    end

    test "TextEncoder returns binary", %{rt: rt} do
      assert {:ok, bin} = QuickBEAM.eval(rt, "new TextEncoder().encode('hello')")
      assert bin == "hello"
    end
  end

  describe "circular and deep object graphs" do
    test "circular reference returns nil for cycle", %{rt: rt} do
      assert {:ok, %{"x" => 1, "self" => nil}} =
               QuickBEAM.eval(rt, "var o = {x: 1}; o.self = o; o")
    end

    test "circular array returns nil for cycle", %{rt: rt} do
      assert {:ok, [1, nil]} =
               QuickBEAM.eval(rt, "var a = [1]; a.push(a); a")
    end

    test "mutual references return nil for cycles", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "var a = {}; var b = {a}; a.b = b; a")
      assert result["b"]["a"] == nil
    end

    test "deeply nested object truncates at max depth", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
          var o = {v: 1}; for(var i=0; i<50; i++) o = {n: o}; o
        """)

      assert is_map(result)
    end

    test "shared references are not confused with cycles", %{rt: rt} do
      assert {:ok, %{"a" => %{"x" => 1}, "b" => %{"x" => 1}}} =
               QuickBEAM.eval(rt, "var shared = {x: 1}; ({a: shared, b: shared})")
    end
  end

  describe "configurable convert limits" do
    test "max_convert_depth limits nesting", _context do
      {:ok, rt} = QuickBEAM.start(max_convert_depth: 2)

      assert {:ok, %{"a" => %{"b" => %{"c" => nil}}}} =
               QuickBEAM.eval(rt, "({a: {b: {c: {d: 42}}}})")
    end

    test "max_convert_nodes limits total nodes", _context do
      {:ok, rt} = QuickBEAM.start(max_convert_nodes: 5)

      {:ok, result} =
        QuickBEAM.eval(rt, """
          ({a: 1, b: 2, c: 3, d: {e: {f: 42}}})
        """)

      assert is_map(result)
      deep = get_in(result, ["d", "e", "f"])
      assert deep == nil
    end

    test "defaults handle normal objects fine", %{rt: rt} do
      assert {:ok, %{"a" => %{"b" => %{"c" => 42}}}} =
               QuickBEAM.eval(rt, "({a: {b: {c: 42}}})")
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

  describe "Beam.call roundtrip" do
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
               QuickBEAM.eval(rt, "await Beam.call('echo', 'hello')")
    end

    test "number roundtrip through beam.call", %{rt: rt} do
      assert {:ok, 84} =
               QuickBEAM.eval(rt, "await Beam.call('double', 42)")
    end

    test "object roundtrip through beam.call", %{rt: rt} do
      assert {:ok, %{"a" => 1}} =
               QuickBEAM.eval(rt, "await Beam.call('echo', {a: 1})")
    end
  end

  describe "Beam.callSync" do
    setup do
      handlers = %{
        "echo" => fn [val] -> val end,
        "double" => fn [n] -> n * 2 end,
        "greet" => fn [name] -> "Hello, #{name}!" end,
        "failing" => fn _ -> raise "boom" end
      }

      {:ok, rt} = QuickBEAM.start(handlers: handlers)
      %{rt: rt}
    end

    test "returns value synchronously (no await)", %{rt: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, "Beam.callSync('echo', 42)")
    end

    test "string roundtrip", %{rt: rt} do
      assert {:ok, "hello"} = QuickBEAM.eval(rt, "Beam.callSync('echo', 'hello')")
    end

    test "object roundtrip", %{rt: rt} do
      assert {:ok, %{"a" => 1}} = QuickBEAM.eval(rt, "Beam.callSync('echo', {a: 1})")
    end

    test "multiple args", %{rt: rt} do
      assert {:ok, 84} = QuickBEAM.eval(rt, "Beam.callSync('double', 42)")
    end

    test "use in expressions (no await needed)", %{rt: rt} do
      assert {:ok, "Hello, world!"} =
               QuickBEAM.eval(rt, "Beam.callSync('greet', 'world')")
    end

    test "use in loops", %{rt: rt} do
      code = """
      let sum = 0;
      for (let i = 1; i <= 5; i++) {
        sum += Beam.callSync('double', i);
      }
      sum
      """

      assert {:ok, 30} = QuickBEAM.eval(rt, code)
    end

    test "error handling with try/catch", %{rt: rt} do
      code = """
      try {
        Beam.callSync('failing');
        'no error';
      } catch (e) {
        'caught: ' + e.message;
      }
      """

      {:ok, result} = QuickBEAM.eval(rt, code)
      assert result =~ "caught:"
    end

    test "unknown handler throws", %{rt: rt} do
      code = """
      try {
        Beam.callSync('nonexistent', 1);
        'no error';
      } catch (e) {
        'caught';
      }
      """

      assert {:ok, "caught"} = QuickBEAM.eval(rt, code)
    end

    test "mixed sync and async calls", %{rt: rt} do
      code = """
      const syncResult = Beam.callSync('echo', 10);
      const asyncResult = await Beam.call('echo', 20);
      syncResult + asyncResult;
      """

      assert {:ok, 30} = QuickBEAM.eval(rt, code)
    end

    test "null roundtrip", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "Beam.callSync('echo', null)")
    end

    test "array roundtrip", %{rt: rt} do
      assert {:ok, [1, 2, 3]} = QuickBEAM.eval(rt, "Beam.callSync('echo', [1, 2, 3])")
    end
  end
end
