defmodule QuickBEAM.WPT.Base64Test do
  @moduledoc "Ported from WPT: base64.any.js"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> if Process.alive?(rt), do: QuickBEAM.stop(rt) end)
    %{rt: rt}
  end

  describe "btoa" do
    test "empty string", %{rt: rt} do
      assert {:ok, ""} = QuickBEAM.eval(rt, "btoa('')")
    end

    test "padding variants", %{rt: rt} do
      assert {:ok, "YQ=="} = QuickBEAM.eval(rt, "btoa('a')")
      assert {:ok, "YWI="} = QuickBEAM.eval(rt, "btoa('ab')")
      assert {:ok, "YWJj"} = QuickBEAM.eval(rt, "btoa('abc')")
      assert {:ok, "YWJjZA=="} = QuickBEAM.eval(rt, "btoa('abcd')")
      assert {:ok, "YWJjZGU="} = QuickBEAM.eval(rt, "btoa('abcde')")
    end

    test "round-trip \\xFF\\xFF\\xC0", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa('\\xFF\\xFF\\xC0')) === '\\xFF\\xFF\\xC0'")
    end

    test "null bytes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa('\\0a')) === '\\0a'")

      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa('a\\0b')) === 'a\\0b'")
    end

    test "all Latin-1 code points round-trip", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               let everything = '';
               for (let i = 0; i < 256; i++) everything += String.fromCharCode(i);
               atob(btoa(everything)) === everything
               """)
    end

    test "non-Latin-1 throws", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "btoa('\\u05D0')")
      assert {:error, _} = QuickBEAM.eval(rt, "btoa(String.fromCharCode(10000))")
    end

    test "WebIDL coercion: undefined", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(undefined)) === 'undefined'")
    end

    test "WebIDL coercion: null", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(null)) === 'null'")
    end

    test "WebIDL coercion: numbers", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(7)) === '7'")

      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(12)) === '12'")

      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(1.5)) === '1.5'")
    end

    test "WebIDL coercion: booleans", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(true)) === 'true'")

      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa(false)) === 'false'")
    end

    test "WebIDL coercion: object with toString", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(btoa({toString: () => 'foo'})) === 'foo'")
    end
  end

  describe "atob" do
    test "basic decode", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               atob('YQ==') === 'a' && atob('YWI=') === 'ab' && atob('YWJj') === 'abc'
               """)
    end

    test "null decodes to bytes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const r = atob(null);
               r.charCodeAt(0) === 158 && r.charCodeAt(1) === 233 && r.charCodeAt(2) === 101
               """)
    end

    test "12 decodes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const r = atob(12);
               r.charCodeAt(0) === 215
               """)
    end

    test "true decodes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const r = atob(true);
               r.charCodeAt(0) === 182 && r.charCodeAt(1) === 187
               """)
    end

    test "NaN decodes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const r = atob(NaN);
               r.charCodeAt(0) === 53 && r.charCodeAt(1) === 163
               """)
    end

    test "+Infinity decodes", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const r = atob(Infinity);
               r.length === 6 && r.charCodeAt(0) === 34
               """)
    end

    test "truly invalid base64 throws", %{rt: rt} do
      assert {:error, _} = QuickBEAM.eval(rt, "atob('!@#$')")
    end

    test "without padding", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob('YQ') === 'a' && atob('YWI') === 'ab'")
    end

    test "whitespace handling", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, "atob(' Y W J j ') === 'abc'")
    end
  end
end
