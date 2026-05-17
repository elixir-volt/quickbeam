defmodule QuickBEAM.VM.Runtime.IteratorTest do
  use QuickBEAM.VMCase, async: true

  test "for-of closes active iterator on thrown body", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let closed=0; let it={ [Symbol.iterator](){return this}, next(){return {value:1,done:false}}, return(){closed=1; return {done:true}}}; try { for (let x of it) { throw new Error("x"); } } catch(e) {} closed|,
      1
    )
  end

  test "for-of keeps iterators open for locally caught throws", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let closed=0; let count=0; let i=0; let it={ [Symbol.iterator](){return this}, next(){ i++; return {value:i, done:i>2}; }, return(){closed++; return {}; } }; for (let x of it) { try { throw new Error("x"); } catch(e) { count++; continue; } } [count, closed].join(",")|,
      "2,0"
    )
  end

  test "for-of closes active iterator when assignment head throws", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let closed = 0; let iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { closed++; return {}; } }; let target = { set value(_) { throw new Error("boom"); } }; try { for (target.value of iter) {} } catch (_) {} closed|,
      1
    )

    assert_modes(
      rt,
      ~S|let closed = 0; let iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done: false }; }, return() { closed++; return {}; } }; let key = "value"; let target = new Proxy({}, { set() { throw new Error("boom"); } }); try { for (target[key] of iter) {} } catch (_) {} closed|,
      1
    )
  end

  test "for-of keeps iterators open for locally caught assignment throws", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let closed = 0; let count = 0; let iter = { i: 0, [Symbol.iterator]() { return this; }, next() { this.i++; return { value: this.i, done: this.i > 2 }; }, return() { closed++; return {}; } }; let target = { set value(_) { throw new Error("boom"); } }; for (let x of iter) { try { target.value = x; } catch (_) { count++; continue; } } [count, closed].join(",")|,
      "2,0"
    )
  end

  test "for-of validates iterator result objects and done truthiness", %{rt: rt} do
    assert_beam_error(
      rt,
      ~S|let iter = { [Symbol.iterator]() { return this; }, next() { return 1; } }; for (let x of iter) {}|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|let caught = false; let iter = { [Symbol.iterator]() { return this; }, next() { return 1; } }; try { for (let x of iter) {} } catch (e) { caught = e.name === "TypeError"; } caught|,
      true
    )

    assert_modes(
      rt,
      ~S|let count = 0; let done = 1; let iter = { [Symbol.iterator]() { return this; }, next() { return { value: 1, done }; } }; for (let x of iter) count++; count|,
      0
    )
  end

  test "for-of accepts callable and regexp iterator results as objects", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      let count = 0;
      let results = [/x/, function() {}];
      let iter = { [Symbol.iterator]() { return this; }, next() { return results[count++] || { done: true }; } };
      for (let x of iter) {}
      count
      """,
      3
    )
  end

  test "iterator next uses iterator receiver", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      let iter = { value: 7, [Symbol.iterator]() { return this; }, next(v) { return { value: this.value + (v || 0), done: false }; }, return() { return {}; } };
      function* g() { yield* iter; }
      let gen = g();
      [gen.next(1).value, gen.return().done].join(",")
      """,
      "7,true"
    )
  end

  test "for-of rejects non-iterable ordinary objects", %{rt: rt} do
    assert_beam_error(rt, ~S|for (let x of {}) {}|, "TypeError")
  end

  test "array for-of reads elements through property access", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let array = []; let count = 0; Object.defineProperty(array, "0", { get() { throw new TypeError("boom"); } }); try { for (let value of array) { count++; } } catch (e) {} count|,
      0
    )
  end

  test "for-of advances built-in list iterators", %{rt: rt} do
    assert_modes(rt, ~S|let out = ""; for (let ch of "abc") out += ch; out|, "abc")
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
