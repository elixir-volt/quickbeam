defmodule QuickBEAM.VM.Runtime.IteratorTest do
  use QuickBEAM.VMCase, async: true

  test "for-of returns through finally cleanup stack", %{rt: rt} do
    assert_modes(
      rt,
      ~S|function* values() { yield 1; throw new Error("unreachable"); } var iterator = values(); var i = 0; var result = (function() { for (var x of iterator) { i++; return 34; } return 0; })(); [result, i].join(",")|,
      "34,1"
    )
  end

  test "for-of closes generators when loop exits abruptly", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var closed = 0; function* values() { try { yield 1; } finally { closed++; } } for (var x of values()) { break; } closed|,
      1
    )
  end

  test "closing a suspended-start generator does not execute its body", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var iterations = 0; var iter = function*() { iterations += 1; }(); for (const [] of [iter]) {} iterations|,
      0
    )
  end

  test "array rest destructuring closes inner iterator on generator return", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var closed = 0; var iterator = { next() { throw new Error("boom"); }, return() { closed++; return {}; } }; var iterable = {}; iterable[Symbol.iterator] = function() { return iterator; }; function* g() { for ([...{}[yield]] of [iterable]) {} } var iter = g(); iter.next(); var result = iter.return(444); [closed, result.value, result.done].join(",")|
           ) == "1,444,true"
  end

  test "array rest destructuring surfaces iterator close errors on generator return", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var returnCountRest = 0; var iteratorRest = { return() { returnCountRest++; throw new Error("close"); } }; var iterableRest = {}; iterableRest[Symbol.iterator] = function() { return iteratorRest; }; function* gRest() { for ([...{}[yield]] of [iterableRest]) {} } var iterRest = gRest(); iterRest.next(); try { iterRest.return(); } catch (e) {} returnCountRest|
           ) == 1
  end

  test "array rest destructuring rejects non-object close results on generator return", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var iteratorRestNull = { return() { return null; } }; var iterableRestNull = {}; iterableRestNull[Symbol.iterator] = function() { return iteratorRestNull; }; function* gRestNull() { for ([...{}[yield]] of [iterableRestNull]) {} } var iterRestNull = gRestNull(); iterRestNull.next(); try { iterRestNull.return(); "no"; } catch (e) { e.name; }|
           ) == "TypeError"
  end

  test "array element destructuring closes inner iterator on generator return", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var returnCountElem = 0; var iteratorElem = { return() { returnCountElem++; throw new Error("close"); } }; var iterableElem = {}; iterableElem[Symbol.iterator] = function() { return iteratorElem; }; function* gElem() { for ([{}[yield]] of [iterableElem]) {} } var iterElem = gElem(); iterElem.next(); try { iterElem.return(); } catch (e) {} returnCountElem|
           ) == 1
  end

  test "array rest destructuring closes inner iterator when target evaluation throws", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var returnCountThrowRest = 0; var caughtThrowRest; var iterableThrowRest = {}; var iteratorThrowRest = { next() { return { done: false }; }, return() { returnCountThrowRest++; return {}; } }; function ThrowRestError() {} function throwRest() { throw new ThrowRestError(); } iterableThrowRest[Symbol.iterator] = function() { return iteratorThrowRest; }; try { for ([...{}[throwRest()]] of [iterableThrowRest]) {} } catch (e) { caughtThrowRest = e instanceof ThrowRestError; } [caughtThrowRest, returnCountThrowRest].join(",")|
           ) == "true,1"
  end

  test "array element destructuring closes inner iterator when target evaluation throws", %{
    rt: rt
  } do
    assert beam!(
             rt,
             ~S|var returnCountThrowElem = 0; var caughtThrowElem; var iterableThrowElem = {}; var iteratorThrowElem = { next() { return { done: true }; }, return() { returnCountThrowElem++; return {}; } }; function ThrowElemError() {} function throwElem() { throw new ThrowElemError(); } iterableThrowElem[Symbol.iterator] = function() { return iteratorThrowElem; }; try { for ([{}[throwElem()]] of [iterableThrowElem]) {} } catch (e) { caughtThrowElem = e instanceof ThrowElemError; } [caughtThrowElem, returnCountThrowElem].join(",")|
           ) == "true,1"
  end

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
      "7,"
    )
  end

  test "for-of finally throw stops outer iteration", %{rt: rt} do
    assert beam!(
             rt,
             ~S"""
             function* values() { yield 1; throw "unreachable"; }
             var iterator = values();
             var i = 0;
             var error = {};
             try {
               for (var x of iterator) {
                 try {} finally { i++; throw error; }
               }
             } catch (e) {}
             i
             """
           ) == 1
  end

  test "generator return resumes yield-star cleanup", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      let closed = false;
      const inner = {
        [Symbol.iterator]() { return this; },
        next() { return { value: 1, done: false }; },
        return() { closed = true; return { done: true }; }
      };
      function* g() { try { yield* inner; } finally { closed = true; } }
      const it = g();
      it.next();
      it.return();
      closed
      """,
      true
    )
  end

  test "for-of rejects non-iterable ordinary objects", %{rt: rt} do
    assert_beam_error(rt, ~S|for (let x of {}) {}|, "TypeError")
  end

  test "array for-of honors own iterator methods", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var customArray = new Array(1, 2); var out = []; customArray[Symbol.iterator] = function* () { yield 9; }; for (let x of customArray) out.push(x); out.join(",")|
           ) == "9"
  end

  test "array for-of rejects non-callable own iterator", %{rt: rt} do
    assert beam!(
             rt,
             ~S|var nonCallableArray = new Array(1); nonCallableArray[Symbol.iterator] = 1; try { for (let x of nonCallableArray) {} "no"; } catch(e) { e.name; }|
           ) == "TypeError"
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
