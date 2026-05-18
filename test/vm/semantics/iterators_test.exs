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

  test "iterator next throws propagate through yield star", %{rt: rt} do
    code = """
    let iterable = {
      [Symbol.iterator]() { return this; },
      next() { throw new TypeError('boom'); }
    };
    function* g() { yield* iterable; }
    let it = g();
    try { it.next(); } catch (e) { e.name + ':' + e.message; }
    """

    assert_modes(rt, code, "TypeError:boom")
  end

  test "for-of resolves Symbol.iterator through accessors", %{rt: rt} do
    code = """
    let calls = 0;
    let obj = {
      get [Symbol.iterator]() {
        calls++;
        return function() {
          let done = false;
          return { next() { if (done) return {done:true}; done = true; return {value: calls, done:false}; } };
        };
      }
    };
    let out;
    for (const value of obj) out = value;
    out;
    """

    assert beam!(rt, code) == 1
  end

  test "array for-of invokes own Symbol.iterator accessors", %{rt: rt} do
    assert beam!(
             rt,
             ~S|const array = [9]; Object.defineProperty(array, Symbol.iterator, { get() { return function* () { yield 1; }; } }); let out; for (const value of array) out = value; out|
           ) == 1
  end

  test "iterator result value is not read when done is true", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let iterable = { [Symbol.iterator]() { return { next() { return { get done() { return true; }, get value() { throw new Error("bad"); } }; } }; } }; for (const value of iterable) { throw new Error("unreachable"); } "done"|
           ) == "done"
  end
end
