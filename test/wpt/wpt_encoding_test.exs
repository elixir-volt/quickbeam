defmodule QuickBEAM.WPT.EncodingTest do
  @moduledoc "Ported from WPT: textdecoder-fatal.any.js, encodeInto.any.js, textdecoder-ignorebom.any.js, textencoder-utf16-surrogates.any.js, api-basics.any.js"
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

  # ── TextDecoder fatal (textdecoder-fatal.any.js) ──

  @fatal_utf8_cases [
    {"invalid code", [0xFF]},
    {"ends early", [0xC0]},
    {"ends early 2", [0xE0]},
    {"invalid trail", [0xC0, 0x00]},
    {"invalid trail 2", [0xC0, 0xC0]},
    {"invalid trail 3", [0xE0, 0x00]},
    {"invalid trail 4", [0xE0, 0xC0]},
    {"invalid trail 5", [0xE0, 0x80, 0x00]},
    {"invalid trail 6", [0xE0, 0x80, 0xC0]},
    {"> 0x10FFFF", [0xFC, 0x80, 0x80, 0x80, 0x80, 0x80]},
    {"obsolete lead byte", [0xFE, 0x80, 0x80, 0x80, 0x80, 0x80]},
    {"overlong U+0000 - 2 bytes", [0xC0, 0x80]},
    {"overlong U+0000 - 3 bytes", [0xE0, 0x80, 0x80]},
    {"overlong U+0000 - 4 bytes", [0xF0, 0x80, 0x80, 0x80]},
    {"overlong U+0000 - 5 bytes", [0xF8, 0x80, 0x80, 0x80, 0x80]},
    {"overlong U+0000 - 6 bytes", [0xFC, 0x80, 0x80, 0x80, 0x80, 0x80]},
    {"overlong U+007F - 2 bytes", [0xC1, 0xBF]},
    {"overlong U+007F - 3 bytes", [0xE0, 0x81, 0xBF]},
    {"overlong U+007F - 4 bytes", [0xF0, 0x80, 0x81, 0xBF]},
    {"overlong U+07FF - 3 bytes", [0xE0, 0x9F, 0xBF]},
    {"overlong U+07FF - 4 bytes", [0xF0, 0x80, 0x9F, 0xBF]},
    {"overlong U+FFFF - 4 bytes", [0xF0, 0x8F, 0xBF, 0xBF]},
    {"lead surrogate", [0xED, 0xA0, 0x80]},
    {"trail surrogate", [0xED, 0xB0, 0x80]},
    {"surrogate pair", [0xED, 0xA0, 0x80, 0xED, 0xB0, 0x80]}
  ]

  describe "TextDecoder fatal UTF-8" do
    for {name, bytes} <- @fatal_utf8_cases do
      @tag_bytes bytes
      test "#{name}", %{rt: rt} do
        bytes_js = "[#{Enum.join(@tag_bytes, ",")}]"

        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 try {
                   new TextDecoder('utf-8', {fatal: true}).decode(new Uint8Array(#{bytes_js}));
                   false;
                 } catch (e) {
                   e instanceof TypeError;
                 }
                 """)
      end
    end

    test "fatal attribute defaults to false", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, "new TextDecoder().fatal")
    end

    test "fatal attribute can be set to true", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "new TextDecoder('utf-8', {fatal: true}).fatal")
    end

    test "error recovery: subsequent valid decode succeeds", %{rt: rt} do
      assert {:ok, "♥"} =
               QuickBEAM.eval(rt, """
               const decoder = new TextDecoder('utf-8', {fatal: true});
               try { decoder.decode(new Uint8Array([0xE2, 0x99])); } catch {}
               decoder.decode(new Uint8Array([0xE2, 0x99, 0xA5]))
               """)
    end
  end

  # ── TextDecoder ignoreBOM (textdecoder-ignorebom.any.js) ──

  describe "TextDecoder ignoreBOM" do
    test "ignoreBOM attribute defaults to false", %{rt: rt} do
      assert {:ok, false} =
               QuickBEAM.eval(rt, "new TextDecoder().ignoreBOM")
    end

    test "ignoreBOM can be set to true", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "new TextDecoder('utf-8', {ignoreBOM: true}).ignoreBOM")
    end

    test "UTF-8 BOM stripped by default", %{rt: rt} do
      assert {:ok, "abc"} =
               QuickBEAM.eval(rt, """
               new TextDecoder('utf-8').decode(new Uint8Array([0xEF, 0xBB, 0xBF, 0x61, 0x62, 0x63]))
               """)
    end

    test "UTF-8 BOM preserved when ignoreBOM=true", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const result = new TextDecoder('utf-8', {ignoreBOM: true}).decode(
                 new Uint8Array([0xEF, 0xBB, 0xBF, 0x61, 0x62, 0x63])
               );
               result === '\\uFEFF' + 'abc'
               """)
    end

    test "BOM stripped on reuse by default", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const decoder = new TextDecoder('utf-8');
               const bytes = new Uint8Array([0xEF, 0xBB, 0xBF, 0x61, 0x62, 0x63]);
               decoder.decode(bytes) === 'abc' && decoder.decode(bytes) === 'abc'
               """)
    end
  end

  # ── TextEncoder.encodeInto (encodeInto.any.js) ──

  @encode_into_cases [
    {"zero dest length", "Hi", 0, 0, []},
    {"single ASCII char", "A", 10, 1, [0x41]},
    {"4-byte char", "\\u{1D306}", 4, 2, [0xF0, 0x9D, 0x8C, 0x86]},
    {"4-byte char won't fit in 3", "\\u{1D306}A", 3, 0, []},
    {"lone surrogates replaced", "\\uD834A\\uDF06A\\u00A5Hi", 10, 5,
     [0xEF, 0xBF, 0xBD, 0x41, 0xEF, 0xBF, 0xBD, 0x41, 0xC2, 0xA5]},
    {"A + lone trail surrogate", "A\\uDF06", 4, 2, [0x41, 0xEF, 0xBF, 0xBD]},
    {"two yen signs", "\\u00A5\\u00A5", 4, 2, [0xC2, 0xA5, 0xC2, 0xA5]}
  ]

  describe "TextEncoder.encodeInto" do
    for {name, input, dest_len, expected_read, expected_written} <- @encode_into_cases do
      @tag_input input
      @tag_dest_len dest_len
      @tag_expected_read expected_read
      @tag_expected_written expected_written

      test "#{name}", %{rt: rt} do
        written_js = "[#{Enum.join(@tag_expected_written, ",")}]"

        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 const encoder = new TextEncoder();
                 const view = new Uint8Array(#{@tag_dest_len});
                 const result = encoder.encodeInto("#{@tag_input}", view);
                 const expected = #{written_js};
                 result.read === #{@tag_expected_read} &&
                   result.written === expected.length &&
                   expected.every((v, i) => view[i] === v)
                 """)
      end
    end

    test "invalid destination types throw TypeError", %{rt: rt} do
      for type <- [
            "Int8Array",
            "Int16Array",
            "Int32Array",
            "Uint16Array",
            "Uint32Array",
            "Float32Array",
            "Float64Array"
          ] do
        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 try {
                   new TextEncoder().encodeInto('', new #{type}(0));
                   false;
                 } catch (e) { e instanceof TypeError; }
                 """)
      end
    end

    test "encodeInto with subarray offset", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const encoder = new TextEncoder();
               const buffer = new ArrayBuffer(14);
               const view = new Uint8Array(buffer, 4, 10);
               const fullView = new Uint8Array(buffer);
               fullView.fill(0x80);
               const result = encoder.encodeInto('A', view);
               result.read === 1 && result.written === 1 &&
                 fullView[4] === 0x41 && fullView[3] === 0x80 && fullView[5] === 0x80
               """)
    end
  end

  # ── TextEncoder surrogate handling (textencoder-utf16-surrogates.any.js) ──

  @surrogate_cases [
    {"lone surrogate lead", "\\uD800", "\\uFFFD"},
    {"lone surrogate trail", "\\uDC00", "\\uFFFD"},
    {"unmatched surrogate lead", "\\uD800\\u0000", "\\uFFFD\\u0000"},
    {"unmatched surrogate trail", "\\uDC00\\u0000", "\\uFFFD\\u0000"},
    {"swapped surrogate pair", "\\uDC00\\uD800", "\\uFFFD\\uFFFD"},
    {"properly encoded MUSICAL SYMBOL G CLEF", "\\uD834\\uDD1E", "\\uD834\\uDD1E"}
  ]

  describe "TextEncoder surrogate handling" do
    for {name, input, expected} <- @surrogate_cases do
      @tag_input input
      @tag_expected expected

      test "#{name}", %{rt: rt} do
        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 const encoded = new TextEncoder().encode("#{@tag_input}");
                 const decoded = new TextDecoder().decode(encoded);
                 decoded === "#{@tag_expected}"
                 """)
      end
    end

    test "encode default is empty", %{rt: rt} do
      assert {:ok, 0} =
               QuickBEAM.eval(rt, "new TextEncoder().encode().length")
    end
  end

  # ── Encode/decode round-trip (api-basics.any.js) ──

  describe "Encoding API basics" do
    test "default encodings", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               new TextEncoder().encoding === 'utf-8' &&
               new TextDecoder().encoding === 'utf-8'
               """)
    end

    test "encode undefined is empty", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "new TextEncoder().encode(undefined).length === 0")
    end

    test "UTF-8 round-trip with non-BMP characters", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const sample = 'z\\xA2\\u6C34\\uD834\\uDD1E\\uF8FF\\uDBFF\\uDFFD\\uFFFE';
               const expectedBytes = [0x7A, 0xC2, 0xA2, 0xE6, 0xB0, 0xB4, 0xF0, 0x9D,
                 0x84, 0x9E, 0xEF, 0xA3, 0xBF, 0xF4, 0x8F, 0xBF, 0xBD, 0xEF, 0xBF, 0xBE];
               const encoded = new TextEncoder().encode(sample);
               const decoded = new TextDecoder('utf-8').decode(new Uint8Array(expectedBytes));
               encoded.length === expectedBytes.length &&
                 encoded.every((v, i) => v === expectedBytes[i]) &&
                 decoded === sample
               """)
    end
  end
end
