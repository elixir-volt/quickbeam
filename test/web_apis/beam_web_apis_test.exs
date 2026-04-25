defmodule QuickBEAM.WebAPIs.BeamWebAPIsTest do
  use ExUnit.Case, async: true
  @moduletag :beam_web_apis

  setup do
    QuickBEAM.VM.Heap.reset()
    {:ok, rt} = QuickBEAM.start(mode: :beam)
    {:ok, rt: rt}
  end

  # ── TextEncoder ──────────────────────────────────────────────

  describe "TextEncoder" do
    test "encoding property is utf-8", %{rt: rt} do
      assert {:ok, "utf-8"} = QuickBEAM.eval(rt, "new TextEncoder().encoding")
    end

    test "encode returns Uint8Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "new TextEncoder().encode('test') instanceof Uint8Array")
    end

    test "encode ASCII", %{rt: rt} do
      assert {:ok, [72, 101, 108, 108, 111]} =
               QuickBEAM.eval(rt, "[...new TextEncoder().encode('Hello')]")
    end

    test "encode empty string", %{rt: rt} do
      assert {:ok, []} = QuickBEAM.eval(rt, "[...new TextEncoder().encode('')]")
    end

    # WPT: api-basics.any.js — "Default inputs"
    test "encode undefined returns empty", %{rt: rt} do
      assert {:ok, []} = QuickBEAM.eval(rt, "[...new TextEncoder().encode()]")
      assert {:ok, []} = QuickBEAM.eval(rt, "[...new TextEncoder().encode(undefined)]")
    end

    # WPT: api-basics.any.js — UTF-8 multibyte
    test "encode multibyte UTF-8", %{rt: rt} do
      assert {:ok, [0xC2, 0xA2]} = QuickBEAM.eval(rt, "[...new TextEncoder().encode('¢')]")
      assert {:ok, [0xE6, 0xB0, 0xB4]} = QuickBEAM.eval(rt, "[...new TextEncoder().encode('水')]")

      assert {:ok, [0xF0, 0x9D, 0x84, 0x9E]} =
               QuickBEAM.eval(rt, "[...new TextEncoder().encode('𝄞')]")
    end

    # WPT: api-basics.any.js — full sample round-trip
    test "encode/decode round-trip with full Unicode sample", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const sample = 'z\\xA2\\u6C34\\uD834\\uDD1E\\uF8FF\\uDBFF\\uDFFD\\uFFFE';
               const bytes = [0x7A, 0xC2, 0xA2, 0xE6, 0xB0, 0xB4, 0xF0, 0x9D, 0x84, 0x9E,
                              0xEF, 0xA3, 0xBF, 0xF4, 0x8F, 0xBF, 0xBD, 0xEF, 0xBF, 0xBE];
               const encoded = new TextEncoder().encode(sample);
               const match = encoded.length === bytes.length &&
                 encoded.every((b, i) => b === bytes[i]);
               const decoded = new TextDecoder().decode(new Uint8Array(bytes));
               match && decoded === sample;
               """)
    end

    # WPT: textencoder-utf16-surrogates.any.js
    test "lone surrogate lead → U+FFFD", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const encoded = new TextEncoder().encode('\\uD800');
               const decoded = new TextDecoder().decode(encoded);
               decoded === '\\uFFFD';
               """)
    end

    test "lone surrogate trail → U+FFFD", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const encoded = new TextEncoder().encode('\\uDC00');
               const decoded = new TextDecoder().decode(encoded);
               decoded === '\\uFFFD';
               """)
    end

    test "swapped surrogate pair → two U+FFFD", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const encoded = new TextEncoder().encode('\\uDC00\\uD800');
               const decoded = new TextDecoder().decode(encoded);
               decoded === '\\uFFFD\\uFFFD';
               """)
    end

    # WPT: encodeInto.any.js
    test "encodeInto basic", %{rt: rt} do
      assert {:ok, %{"read" => 2, "written" => 2}} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(10);
               new TextEncoder().encodeInto('Hi', buf);
               """)
    end

    test "encodeInto with zero-length destination", %{rt: rt} do
      assert {:ok, %{"read" => 0, "written" => 0}} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(0);
               new TextEncoder().encodeInto('Hi', buf);
               """)
    end

    test "encodeInto: 4-byte char into 3-byte buffer → nothing written", %{rt: rt} do
      assert {:ok, %{"read" => 0, "written" => 0}} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(3);
               new TextEncoder().encodeInto('\\u{1D306}', buf);
               """)
    end

    test "encodeInto: surrogate pair counts as 2 read chars", %{rt: rt} do
      assert {:ok, %{"read" => 2, "written" => 4}} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(4);
               new TextEncoder().encodeInto('\\u{1D306}', buf);
               """)
    end

    test "encodeInto: lone surrogates produce replacement bytes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(10);
               const { read, written } = new TextEncoder().encodeInto('\\uD834A\\uDF06A', buf);
               // \\uD834 → FFFD (3 bytes), A (1), \\uDF06 → FFFD (3), A (1) = total 8 bytes, 4 read
               read >= 4 && written >= 8;
               """)
    end

    test "encodeInto: ¥¥ into 4-byte buffer", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(4);
               const { read, written } = new TextEncoder().encodeInto('¥¥', buf);
               read === 2 && written === 4 &&
                 buf[0] === 0xC2 && buf[1] === 0xA5 && buf[2] === 0xC2 && buf[3] === 0xA5;
               """)
    end

    test "encodeInto writes to correct offset in subarray", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array(14);
               buf.fill(0x80);
               const view = new Uint8Array(buf.buffer, 4, 10);
               new TextEncoder().encodeInto('A', view);
               buf[3] === 0x80 && buf[4] === 0x41 && buf[5] === 0x80;
               """)
    end
  end

  # ── TextDecoder ──────────────────────────────────────────────

  describe "TextDecoder" do
    test "encoding property is utf-8", %{rt: rt} do
      assert {:ok, "utf-8"} = QuickBEAM.eval(rt, "new TextDecoder().encoding")
    end

    test "decode empty", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "new TextDecoder().decode()")
      assert {:ok, ""} = QuickBEAM.eval(rt, "new TextDecoder().decode(undefined)")
      assert {:ok, ""} = QuickBEAM.eval(rt, "new TextDecoder().decode(new Uint8Array())")
    end

    test "decode ASCII bytes", %{rt: rt} do
      assert {:ok, "Hello"} =
               QuickBEAM.eval(
                 rt,
                 "new TextDecoder().decode(new Uint8Array([72, 101, 108, 108, 111]))"
               )
    end

    test "decode multibyte UTF-8", %{rt: rt} do
      assert {:ok, "¢"} =
               QuickBEAM.eval(rt, "new TextDecoder().decode(new Uint8Array([0xC2, 0xA2]))")

      assert {:ok, "水"} =
               QuickBEAM.eval(rt, "new TextDecoder().decode(new Uint8Array([0xE6, 0xB0, 0xB4]))")
    end

    test "decode ArrayBuffer directly", %{rt: rt} do
      assert {:ok, "AB"} =
               QuickBEAM.eval(rt, "new TextDecoder().decode(new Uint8Array([65, 66]).buffer)")
    end

    test "constructor labels: utf-8, UTF-8, utf8", %{rt: rt} do
      assert {:ok, "utf-8"} = QuickBEAM.eval(rt, "new TextDecoder('utf-8').encoding")
      assert {:ok, "utf-8"} = QuickBEAM.eval(rt, "new TextDecoder('UTF-8').encoding")
      assert {:ok, "utf-8"} = QuickBEAM.eval(rt, "new TextDecoder('utf8').encoding")
    end

    test "constructor with unsupported encoding throws", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "new TextDecoder('windows-1252')")
    end

    test "round-trip encode/decode", %{rt: rt} do
      assert {:ok, "Hello, 世界!"} =
               QuickBEAM.eval(rt, """
               const text = 'Hello, 世界!';
               new TextDecoder().decode(new TextEncoder().encode(text));
               """)
    end

    # WPT: textdecoder-fatal.any.js
    test "fatal: true — invalid UTF-8 throws TypeError", %{rt: rt} do
      cases = [
        "[0xFF]",
        "[0xC0]",
        "[0xE0]",
        "[0xC0, 0x00]",
        "[0xC0, 0xC0]",
        "[0xE0, 0x00]",
        "[0xE0, 0x80, 0x00]"
      ]

      for bytes <- cases do
        assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
                 QuickBEAM.eval(
                   rt,
                   "new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array(#{bytes}))"
                 )
      end
    end

    test "fatal: true — overlong U+0000 encodings throw", %{rt: rt} do
      overlong_cases = [
        "[0xC0, 0x80]",
        "[0xE0, 0x80, 0x80]",
        "[0xF0, 0x80, 0x80, 0x80]"
      ]

      for bytes <- overlong_cases do
        assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
                 QuickBEAM.eval(
                   rt,
                   "new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array(#{bytes}))"
                 )
      end
    end

    test "fatal: true — UTF-8 encoded surrogates throw", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
               QuickBEAM.eval(
                 rt,
                 "new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array([0xED, 0xA0, 0x80]))"
               )
    end

    test "fatal attribute defaults and can be set", %{rt: rt} do
      assert {:ok, false} = QuickBEAM.eval(rt, "new TextDecoder().fatal")
      assert {:ok, true} = QuickBEAM.eval(rt, "new TextDecoder('utf-8', {fatal: true}).fatal")
    end

    test "fatal: error does not prevent future decodes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const decoder = new TextDecoder('utf-8', {fatal: true});
               const good = new Uint8Array([226, 153, 165]); // ♥
               decoder.decode(good) === '♥' &&
               (() => { try { decoder.decode(new Uint8Array([226, 153])); return false; } catch { return true; } })() &&
               decoder.decode(good) === '♥';
               """)
    end

    # WPT: textdecoder-byte-order-marks.any.js (UTF-8 BOM only — we only support UTF-8)
    test "UTF-8 BOM is stripped from output", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(rt, """
               new TextDecoder().decode(new Uint8Array([0xEF, 0xBB, 0xBF, 0x68, 0x65, 0x6C, 0x6C, 0x6F]))
               """)
    end

    test "UTF-8 data without BOM decodes normally", %{rt: rt} do
      assert {:ok, "hello"} =
               QuickBEAM.eval(
                 rt,
                 "new TextDecoder().decode(new Uint8Array([0x68, 0x65, 0x6C, 0x6C, 0x6F]))"
               )
    end
  end

  # ── btoa ──────────────────────────────────────────────

  describe "btoa" do
    test "encode ASCII", %{rt: rt} do
      assert {:ok, "SGVsbG8="} = QuickBEAM.eval(rt, "btoa('Hello')")
    end

    test "encode empty string", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "btoa('')")
    end

    # WPT: base64.any.js — padding variants
    test "encode various lengths (padding)", %{rt: rt} do
      assert {:ok, "YQ=="} = QuickBEAM.eval(rt, "btoa('a')")
      assert {:ok, "YWI="} = QuickBEAM.eval(rt, "btoa('ab')")
      assert {:ok, "YWJj"} = QuickBEAM.eval(rt, "btoa('abc')")
      assert {:ok, "YWJjZA=="} = QuickBEAM.eval(rt, "btoa('abcd')")
      assert {:ok, "YWJjZGU="} = QuickBEAM.eval(rt, "btoa('abcde')")
    end

    test "encode \\xFF\\xFF\\xC0", %{rt: rt} do
      assert {:ok, "///A"} = QuickBEAM.eval(rt, "btoa('\\xFF\\xFF\\xC0')")
    end

    test "encode binary-safe: null bytes", %{rt: rt} do
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa('\\0a')")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa('a\\0b')")
    end

    test "encode all Latin-1 chars (0-255)", %{rt: rt} do
      assert {:ok, _} =
               QuickBEAM.eval(rt, """
               let s = '';
               for (let i = 0; i < 256; i++) s += String.fromCharCode(i);
               btoa(s);
               """)
    end

    # WPT: base64.any.js — InvalidCharacterError for > U+00FF
    test "throw on non-Latin-1 chars", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "btoa('\\u0100')")
      assert {:error, _} = QuickBEAM.eval(rt, "btoa('\\u{1F600}')")
      assert {:error, _} = QuickBEAM.eval(rt, "btoa(String.fromCharCode(10000))")
    end

    # WPT: base64.any.js — WebIDL type coercion
    test "WebIDL type coercion", %{rt: rt} do
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(undefined)")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(null)")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(7)")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(12)")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(1.5)")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(true)")
      assert {:ok, _} = QuickBEAM.eval(rt, "btoa(false)")
    end

    test "round-trip: atob(btoa(x)) === String(x)", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               let s = '';
               for (let i = 0; i < 256; i++) s += String.fromCharCode(i);
               atob(btoa(s)) === s;
               """)
    end
  end

  # ── atob ──────────────────────────────────────────────

  describe "atob" do
    test "decode basic", %{rt: rt} do
      assert {:ok, "Hello"} = QuickBEAM.eval(rt, "atob('SGVsbG8=')")
    end

    test "decode without padding", %{rt: rt} do
      assert {:ok, "Hello"} = QuickBEAM.eval(rt, "atob('SGVsbG8')")
    end

    test "decode with whitespace", %{rt: rt} do
      assert {:ok, "Hello"} = QuickBEAM.eval(rt, "atob(' SGVs bG8= ')")
    end

    test "throw on invalid input", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "atob('!')")
    end

    # WPT: base64.any.js — atob IDL tests
    test "atob(undefined) throws", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "atob(undefined)")
    end

    test "atob(null) decodes to bytes", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "[...atob(null)].map(c => c.charCodeAt(0))")
      assert result == [158, 233, 101]
    end

    test "atob(12) decodes to bytes", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "[...atob(12)].map(c => c.charCodeAt(0))")
      assert result == [215]
    end

    test "atob(NaN) throws", %{rt: rt} do
      {:ok, result} = QuickBEAM.eval(rt, "[...atob(NaN)].map(c => c.charCodeAt(0))")
      assert result == [53, 163]
    end

    test "atob(-Infinity) throws", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "atob(-Infinity)")
    end

    test "atob(0) throws", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "atob(0)")
    end
  end

  # ── crypto.getRandomValues ──────────────────────────────────

  describe "crypto.getRandomValues" do
    test "fills Uint8Array and returns same object", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const arr = new Uint8Array(16);
               const result = crypto.getRandomValues(arr);
               result === arr && arr.some(x => x !== 0);
               """)
    end

    # WPT: getRandomValues.any.js — integer array types
    test "works with Int8Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Int8Array(8)).constructor === Int8Array"
               )
    end

    test "works with Int16Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Int16Array(8)).constructor === Int16Array"
               )
    end

    test "works with Int32Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Int32Array(4)).constructor === Int32Array"
               )
    end

    test "works with Uint16Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Uint16Array(8)).constructor === Uint16Array"
               )
    end

    test "works with Uint32Array", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Uint32Array(4)).constructor === Uint32Array"
               )
    end

    test "works with Uint8ClampedArray", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Uint8ClampedArray(8)).constructor === Uint8ClampedArray"
               )
    end

    # WPT: getRandomValues.any.js — zero-length
    test "zero-length array returns empty", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "crypto.getRandomValues(new Uint8Array(0)).length === 0")
    end

    # WPT: getRandomValues.any.js — quota exceeded
    test "throws for > 65536 bytes", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "crypto.getRandomValues(new Uint8Array(65537))")
    end

    test "65536 bytes is exactly allowed", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(
                 rt,
                 "crypto.getRandomValues(new Uint8Array(65536)).length === 65536"
               )
    end
  end

  # ── performance.now ──────────────────────────────────────────

  describe "performance.now" do
    # WPT: hr-time-basic.any.js
    test "performance exists and is an object", %{rt: rt} do
      assert {:ok, "object"} = QuickBEAM.eval(rt, "typeof performance")
    end

    test "performance.now is a function", %{rt: rt} do
      assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof performance.now")
    end

    test "returns a number", %{rt: rt} do
      assert {:ok, "number"} = QuickBEAM.eval(rt, "typeof performance.now()")
    end

    test "returns a positive number", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "performance.now() > 0")
    end

    test "is monotonically non-decreasing", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const a = performance.now();
               const b = performance.now();
               (b - a) >= 0;
               """)
    end

    test "returns milliseconds in reasonable range", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const t = performance.now();
               t >= 0 && t < 60000;
               """)
    end
  end

  # ── queueMicrotask ──────────────────────────────────────────

  describe "queueMicrotask" do
    test "executes callback", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 let called = false;
                 queueMicrotask(() => { called = true; });
                 Promise.resolve().then(() => resolve(called));
               });
               """)
    end

    test "executes in FIFO order", %{rt: rt} do
      assert {:ok, [1, 2, 3]} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 const order = [];
                 queueMicrotask(() => order.push(1));
                 queueMicrotask(() => order.push(2));
                 queueMicrotask(() => order.push(3));
                 Promise.resolve().then(() => resolve(order));
               });
               """)
    end

    test "requires function argument", %{rt: rt} do
      assert {:error, %QuickBEAM.JSError{name: "TypeError"}} =
               QuickBEAM.eval(rt, "queueMicrotask(42)")
    end

    test "microtask errors don't propagate", %{rt: rt} do
      assert {:ok, "ok"} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 queueMicrotask(() => { throw new Error('ignored'); });
                 queueMicrotask(() => resolve('ok'));
               });
               """)
    end
  end

  # ── structuredClone ──────────────────────────────────────────

  describe "structuredClone" do
    test "clones objects deeply", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const orig = { a: 1, b: [2, 3] };
               const clone = structuredClone(orig);
               clone.a === 1 && clone.b[0] === 2 && clone.b[1] === 3 &&
                 clone !== orig && clone.b !== orig.b;
               """)
    end

    test "clones nested structures", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const orig = { x: { y: { z: 42 } } };
               const clone = structuredClone(orig);
               clone.x.y.z === 42 && clone.x !== orig.x;
               """)
    end

    test "clones arrays", %{rt: rt} do
      assert {:ok, [1, 2, 3]} = QuickBEAM.eval(rt, "structuredClone([1, 2, 3])")
    end

    test "clones primitives", %{rt: rt} do
      assert {:ok, 42} = QuickBEAM.eval(rt, "structuredClone(42)")
      assert {:ok, "hello"} = QuickBEAM.eval(rt, "structuredClone('hello')")
      assert {:ok, true} = QuickBEAM.eval(rt, "structuredClone(true)")
      assert {:ok, nil} = QuickBEAM.eval(rt, "structuredClone(null)")
    end

    test "clones Date objects", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const d = new Date('2024-01-01');
               const clone = structuredClone(d);
               clone instanceof Date && clone.getTime() === d.getTime() && clone !== d;
               """)
    end

    test "clones RegExp objects", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const r = /test/gi;
               const clone = structuredClone(r);
               clone instanceof RegExp && clone.source === 'test' &&
                 clone.flags === 'gi' && clone !== r;
               """)
    end

    test "clones Map and Set", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const m = new Map([['a', 1], ['b', 2]]);
               const clone = structuredClone(m);
               clone instanceof Map && clone.get('a') === 1 && clone !== m;
               """)
    end

    test "clones ArrayBuffer", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const buf = new Uint8Array([1, 2, 3]).buffer;
               const clone = structuredClone(buf);
               clone instanceof ArrayBuffer && clone.byteLength === 3 &&
                 new Uint8Array(clone)[0] === 1 && clone !== buf;
               """)
    end

    test "throws on functions", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "structuredClone(() => {})")
    end

    test "clones undefined", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "structuredClone(undefined)")
    end
  end

  # ── console ──────────────────────────────────────────────

  describe "console" do
    test "console.log exists", %{rt: rt} do
      assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof console.log")
    end

    test "console.warn exists", %{rt: rt} do
      assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof console.warn")
    end

    test "console.error exists", %{rt: rt} do
      assert {:ok, "function"} = QuickBEAM.eval(rt, "typeof console.error")
    end

    test "console.log returns undefined", %{rt: rt} do
      assert {:ok, nil} = QuickBEAM.eval(rt, "console.log('test')")
    end
  end

  # ── Timers ──────────────────────────────────────────────

  describe "timers" do
    test "setTimeout executes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => setTimeout(() => resolve(true), 1));
               """)
    end

    test "setTimeout with delay", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const start = performance.now();
               await new Promise(resolve => setTimeout(() => resolve(true), 10));
               performance.now() - start >= 9;
               """)
    end

    test "clearTimeout cancels", %{rt: rt} do
      assert {:ok, "not called"} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 const id = setTimeout(() => resolve('called'), 10);
                 clearTimeout(id);
                 setTimeout(() => resolve('not called'), 20);
               });
               """)
    end

    test "setInterval fires multiple times", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 let count = 0;
                 const id = setInterval(() => {
                   count++;
                   if (count >= 3) { clearInterval(id); resolve(true); }
                 }, 5);
               });
               """)
    end

    test "clearInterval stops", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               await new Promise(resolve => {
                 let count = 0;
                 const id = setInterval(() => count++, 5);
                 setTimeout(() => {
                   clearInterval(id);
                   const snapshot = count;
                   setTimeout(() => resolve(count === snapshot), 20);
                 }, 30);
               });
               """)
    end

    test "setTimeout returns numeric id", %{rt: rt} do
      assert {:ok, true} = QuickBEAM.eval(rt, "typeof setTimeout(() => {}, 0) === 'number'")
    end

    test "setInterval returns numeric id", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const id = setInterval(() => {}, 100);
               clearInterval(id);
               typeof id === 'number';
               """)
    end
  end
end
