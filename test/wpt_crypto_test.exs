defmodule QuickBEAM.WPT.CryptoTest do
  @moduledoc "Ported from WPT: getRandomValues.any.js"
  use ExUnit.Case, async: true

  setup do
    {:ok, rt} = QuickBEAM.start()
    on_exit(fn -> catch_exit(QuickBEAM.stop(rt)) end)
    %{rt: rt}
  end

  describe "getRandomValues integer arrays" do
    for type <- ~w[Int8Array Int16Array Int32Array Uint8Array Uint8ClampedArray Uint16Array Uint32Array] do
      @tag_type type
      test "#{type} returns same object", %{rt: rt} do
        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 const arr = new #{@tag_type}(8);
                 crypto.getRandomValues(arr) === arr
                 """)
      end

      test "#{type} zero length works", %{rt: rt} do
        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 crypto.getRandomValues(new #{@tag_type}(0)).length === 0
                 """)
      end

      test "#{type} quota exceeded throws", %{rt: rt} do
        assert {:error, _} =
                 QuickBEAM.eval(rt, """
                 const maxlen = 65536 / #{@tag_type}.BYTES_PER_ELEMENT;
                 crypto.getRandomValues(new #{@tag_type}(maxlen + 1));
                 """)
      end
    end
  end

  describe "getRandomValues float arrays throw TypeMismatchError" do
    for type <- ~w[Float32Array Float64Array] do
      @tag_type type
      test "#{type} throws DOMException", %{rt: rt} do
        assert {:ok, true} =
                 QuickBEAM.eval(rt, """
                 try {
                   crypto.getRandomValues(new #{@tag_type}(6));
                   false;
                 } catch (e) { e instanceof DOMException && e.name === 'TypeMismatchError'; }
                 """)
      end
    end
  end

  describe "getRandomValues DataView throws" do
    test "DataView throws DOMException", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               try {
                 crypto.getRandomValues(new DataView(new ArrayBuffer(6)));
                 false;
               } catch (e) { e instanceof DOMException && e.name === 'TypeMismatchError'; }
               """)
    end
  end

  describe "getRandomValues non-zero output" do
    test "Uint8Array gets random data", %{rt: rt} do
      assert {:ok, true} =
               QuickBEAM.eval(rt, """
               const arr = crypto.getRandomValues(new Uint8Array(64));
               arr.some(v => v !== 0)
               """)
    end
  end
end
