defmodule QuickBEAM.VM.Semantics.IteratorsTest do
  use QuickBEAM.VMCase, async: true

  test "array spread rejects present non-callable iterator", %{rt: rt} do
    assert_beam_error(rt, "[...{ [Symbol.iterator]: 1 }]", "TypeError")
  end

  test "array spread uses JS truthiness for iterator done", %{rt: rt} do
    assert beam!(rt, """
           let calls = 0;
           let iterator = {
             next() {
               if (calls++) return { done: true };
               return { done: 0, value: 7 };
             }
           };
           let iterable = { [Symbol.iterator]() { return iterator; } };
           [...iterable][0];
           """) == 7
  end

  test "for-of string iteration preserves astral code point width", %{rt: rt} do
    assert_modes(rt, ~S|let out; for (const ch of "😀a") { out = ch.length; break; } out|, 2)
  end
end
