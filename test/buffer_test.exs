defmodule QuickBEAM.BufferTest do
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> try do QuickBEAM.stop(rt) catch :exit, _ -> :ok end end)
    %{rt: rt}
  end

  describe "Buffer.from" do
    test "from utf8 string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello').toString()")
      assert result == "hello"
    end

    test "from utf8 with multi-byte", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('привет').toString()")
      assert result == "привет"
    end

    test "from hex string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('48656c6c6f', 'hex').toString()")
      assert result == "Hello"
    end

    test "from base64 string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('SGVsbG8=', 'base64').toString()")
      assert result == "Hello"
    end

    test "from base64url string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('SGVsbG8', 'base64url').toString()")
      assert result == "Hello"
    end

    test "from latin1 string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('café', 'latin1').length")
      assert result == 4
    end

    test "from ascii string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello', 'ascii').toString('ascii')")
      assert result == "hello"
    end

    test "from array", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from([72, 101, 108, 108, 111]).toString()")
      assert result == "Hello"
    end

    test "from Uint8Array", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, "Buffer.from(new Uint8Array([72, 101, 108, 108, 111])).toString()")

      assert result == "Hello"
    end

    test "from ArrayBuffer", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const ab = new Uint8Array([72, 101, 108, 108, 111]).buffer;
        Buffer.from(ab).toString()
        """)

      assert result == "Hello"
    end

    test "from ArrayBuffer with offset and length", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const ab = new Uint8Array([0, 72, 101, 108, 108, 111, 0]).buffer;
        Buffer.from(ab, 1, 5).toString()
        """)

      assert result == "Hello"
    end

    test "from JSON object", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(
          rt,
          "Buffer.from({type: 'Buffer', data: [72, 101, 108, 108, 111]}).toString()"
        )

      assert result == "Hello"
    end
  end

  describe "Buffer.toString" do
    test "to hex", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('Hello').toString('hex')")
      assert result == "48656c6c6f"
    end

    test "to base64", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('Hello').toString('base64')")
      assert result == "SGVsbG8="
    end

    test "to base64url", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('Hello').toString('base64url')")
      assert result == "SGVsbG8"
    end

    test "to latin1", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from([0xc0, 0xff, 0xe9]).toString('latin1')")
      assert result == "Àÿé"
    end

    test "with start and end", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('Hello World').toString('utf8', 0, 5)")
      assert result == "Hello"
    end

    test "default is utf8", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello').toString()")
      assert result == "hello"
    end
  end

  describe "Buffer.alloc" do
    test "zero-filled", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.alloc(5).every(b => b === 0)")
      assert result == true
    end

    test "with fill byte", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.alloc(3, 0x42).toString()")
      assert result == "BBB"
    end

    test "with fill string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.alloc(5, 'ab').toString()")
      assert result == "ababa"
    end
  end

  describe "Buffer.concat" do
    test "concatenates buffers", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const a = Buffer.from('Hello');
        const b = Buffer.from(' ');
        const c = Buffer.from('World');
        Buffer.concat([a, b, c]).toString()
        """)

      assert result == "Hello World"
    end

    test "with totalLength truncation", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        Buffer.concat([Buffer.from('Hello'), Buffer.from(' World')], 5).toString()
        """)

      assert result == "Hello"
    end
  end

  describe "Buffer.compare" do
    test "equal buffers", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.compare(Buffer.from('abc'), Buffer.from('abc'))")
      assert result == 0
    end

    test "less than", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.compare(Buffer.from('abc'), Buffer.from('abd'))")
      assert result == -1
    end

    test "greater than", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.compare(Buffer.from('abd'), Buffer.from('abc'))")
      assert result == 1
    end
  end

  describe "Buffer.isBuffer" do
    test "true for Buffer", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.isBuffer(Buffer.from('hello'))")
      assert result == true
    end

    test "false for Uint8Array", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.isBuffer(new Uint8Array(5))")
      assert result == false
    end

    test "false for string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.isBuffer('hello')")
      assert result == false
    end
  end

  describe "Buffer.isEncoding" do
    test "known encodings", %{rt: rt} do
      for enc <- ~w[utf8 utf-8 ascii latin1 binary base64 base64url hex ucs2 utf16le] do
        {:ok, result} = QuickBEAM.eval(rt, "Buffer.isEncoding('#{enc}')")
        assert result == true, "expected #{enc} to be a valid encoding"
      end
    end

    test "unknown encoding", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.isEncoding('nope')")
      assert result == false
    end
  end

  describe "Buffer.byteLength" do
    test "utf8", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.byteLength('привет')")
      assert result == 12
    end

    test "hex", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.byteLength('48656c6c6f', 'hex')")
      assert result == 5
    end

    test "base64", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.byteLength('SGVsbG8=', 'base64')")
      assert result == 5
    end
  end

  describe "read/write integers" do
    test "UInt8", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(1);
        buf.writeUInt8(255);
        buf.readUInt8()
        """)

      assert result == 255
    end

    test "UInt16BE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(2);
        buf.writeUInt16BE(0x1234);
        buf.readUInt16BE()
        """)

      assert result == 0x1234
    end

    test "UInt16LE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(2);
        buf.writeUInt16LE(0x1234);
        buf.readUInt16LE()
        """)

      assert result == 0x1234
    end

    test "UInt32BE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(4);
        buf.writeUInt32BE(0xDEADBEEF);
        buf.readUInt32BE()
        """)

      assert result == 0xDEADBEEF
    end

    test "UInt32LE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(4);
        buf.writeUInt32LE(0xDEADBEEF);
        buf.readUInt32LE()
        """)

      assert result == 0xDEADBEEF
    end

    test "Int8 negative", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(1);
        buf.writeInt8(-42);
        buf.readInt8()
        """)

      assert result == -42
    end

    test "Int16BE negative", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(2);
        buf.writeInt16BE(-1000);
        buf.readInt16BE()
        """)

      assert result == -1000
    end

    test "Int32LE negative", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(4);
        buf.writeInt32LE(-123456);
        buf.readInt32LE()
        """)

      assert result == -123_456
    end
  end

  describe "read/write floats" do
    test "FloatBE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(4);
        buf.writeFloatBE(3.14);
        Math.abs(buf.readFloatBE() - 3.14) < 0.001
        """)

      assert result == true
    end

    test "DoubleBE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(8);
        buf.writeDoubleBE(3.141592653589793);
        buf.readDoubleBE()
        """)

      assert_in_delta result, 3.141592653589793, 1.0e-15
    end

    test "DoubleLE", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(8);
        buf.writeDoubleLE(2.718281828);
        buf.readDoubleLE()
        """)

      assert_in_delta result, 2.718281828, 1.0e-9
    end
  end

  describe "slice and subarray" do
    test "slice returns Buffer", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.from('Hello World');
        const sliced = buf.slice(0, 5);
        Buffer.isBuffer(sliced) && sliced.toString() === 'Hello'
        """)

      assert result == true
    end

    test "subarray returns Buffer", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.from('Hello World');
        const sub = buf.subarray(6);
        Buffer.isBuffer(sub) && sub.toString() === 'World'
        """)

      assert result == true
    end
  end

  describe "copy" do
    test "copies bytes", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const src = Buffer.from('Hello');
        const dst = Buffer.alloc(5);
        src.copy(dst);
        dst.toString()
        """)

      assert result == "Hello"
    end

    test "partial copy", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const src = Buffer.from('Hello World');
        const dst = Buffer.alloc(5);
        src.copy(dst, 0, 6, 11);
        dst.toString()
        """)

      assert result == "World"
    end
  end

  describe "write" do
    test "writes string", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(5);
        buf.write('Hello');
        buf.toString()
        """)

      assert result == "Hello"
    end

    test "writes with offset", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(11);
        buf.write('Hello');
        buf.write(' World', 5);
        buf.toString()
        """)

      assert result == "Hello World"
    end

    test "returns bytes written", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.alloc(3);
        buf.write('Hello')
        """)

      assert result == 3
    end
  end

  describe "indexOf and includes" do
    test "finds byte", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello').indexOf(0x6c)")
      assert result == 2
    end

    test "finds string", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello world').indexOf('world')")
      assert result == 6
    end

    test "returns -1 when not found", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello').indexOf('xyz')")
      assert result == -1
    end

    test "includes", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('hello world').includes('world')")
      assert result == true
    end

    test "lastIndexOf", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('abcabc').lastIndexOf('abc')")
      assert result == 3
    end
  end

  describe "equals" do
    test "equal buffers", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('abc').equals(Buffer.from('abc'))")
      assert result == true
    end

    test "unequal buffers", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('abc').equals(Buffer.from('xyz'))")
      assert result == false
    end
  end

  describe "fill" do
    test "fill with byte", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.alloc(3, 0x41).toString()")
      assert result == "AAA"
    end

    test "fill with string pattern", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.alloc(6, 'abc').toString()")
      assert result == "abcabc"
    end
  end

  describe "swap" do
    test "swap16", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.from([0x01, 0x02, 0x03, 0x04]);
        buf.swap16();
        [buf[0], buf[1], buf[2], buf[3]]
        """)

      assert result == [0x02, 0x01, 0x04, 0x03]
    end

    test "swap32", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.from([0x01, 0x02, 0x03, 0x04]);
        buf.swap32();
        [buf[0], buf[1], buf[2], buf[3]]
        """)

      assert result == [0x04, 0x03, 0x02, 0x01]
    end

    test "swap16 rejects odd length", %{rt: rt} do
      {:error, _} = QuickBEAM.eval(rt, "Buffer.alloc(3).swap16()")
    end
  end

  describe "toJSON" do
    test "returns type and data", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('Hi').toJSON()")
      assert result == %{"type" => "Buffer", "data" => [72, 105]}
    end
  end

  describe "BEAM interop" do
    test "Buffer round-trips as binary", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.from('Hello BEAM')")
      assert result == "Hello BEAM"
    end

    test "BEAM binary usable as Buffer.from input", %{rt: rt} do
      QuickBEAM.eval(rt, "function processBuffer(b) { return Buffer.from(b).toString('hex') }")
      {:ok, result} = QuickBEAM.call(rt, "processBuffer", [{:bytes, <<0xDE, 0xAD, 0xBE, 0xEF>>}])
      assert result == "deadbeef"
    end

    test "hex encoding via BEAM", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.from([0xCA, 0xFE, 0xBA, 0xBE]);
        buf.toString('hex')
        """)

      assert result == "cafebabe"
    end

    test "base64 round-trip via BEAM", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const encoded = Buffer.from('Hello BEAM!').toString('base64');
        Buffer.from(encoded, 'base64').toString()
        """)

      assert result == "Hello BEAM!"
    end

    test "utf16le encoding via BEAM", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const buf = Buffer.from('Hi', 'utf16le');
        buf.length
        """)

      assert result == 4
    end
  end

  describe "instance compare" do
    test "compare method", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const a = Buffer.from('abc');
        const b = Buffer.from('abd');
        a.compare(b)
        """)

      assert result == -1
    end

    test "compare with ranges", %{rt: rt} do
      {:ok, result} =
        QuickBEAM.eval(rt, """
        const a = Buffer.from('xxabc');
        const b = Buffer.from('abc');
        a.compare(b, 0, 3, 2, 5)
        """)

      assert result == 0
    end
  end

  describe "allocUnsafe" do
    test "returns buffer of correct size", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "Buffer.allocUnsafe(10).length")
      assert result == 10
    end
  end
end
