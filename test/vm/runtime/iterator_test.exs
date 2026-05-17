defmodule QuickBEAM.VM.Runtime.IteratorTest do
  use QuickBEAM.VMCase, async: true

  test "for-of closes active iterator on thrown body", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let closed=0; let it={ [Symbol.iterator](){return this}, next(){return {value:1,done:false}}, return(){closed=1; return {done:true}}}; try { for (let x of it) { throw new Error("x"); } } catch(e) {} closed|,
      1
    )
  end

  test "for-of closes active iterator when assignment head throws", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let closed = 0; let iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { closed++; return {}; } }; let target = { set value(_) { throw new Error("boom"); } }; try { for (target.value of iter) {} } catch (_) {} closed|
           ) == 1
  end

  test "for-of rejects non-object iterator close result", %{rt: rt} do
    assert_beam_error(
      rt,
      ~S|let iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { return null; } }; for (let x of iter) { break; }|,
      "TypeError"
    )
  end

  test "Iterator.from wraps arbitrary self-iterables before helper validation", %{rt: rt} do
    assert beam!(rt, """
           let closed = 0;
           let iterator = {
             next() { return { done: true }; },
             return() { closed++; },
             [Symbol.iterator]() { return this; }
           };
           try { Iterator.from(iterator).map(1); } catch (e) {}
           closed;
           """) == 0
  end
end
