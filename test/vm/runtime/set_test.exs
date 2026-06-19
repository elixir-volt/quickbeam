defmodule QuickBEAM.VM.Runtime.SetTest do
  use QuickBEAM.VM.TestCase, async: true

  test "iteration visits delete-then-readd entries", %{rt: rt} do
    assert beam!(rt, """
           let set = new Set([1, 2]);
           let iterator = set.values();
           let values = [iterator.next().value];
           set.delete(2);
           set.add(2);
           values.push(iterator.next().value);
           values.join(',');
           """) == "1,2"
  end

  test "forEach visits delete-then-readd entries", %{rt: rt} do
    assert beam!(rt, """
           let set = new Set([1, 2]);
           let values = [];
           set.forEach(value => {
             values.push(value);
             if (value === 1) {
               set.delete(2);
               set.add(2);
             }
           });
           values.join(',');
           """) == "1,2"
  end

  test "constructor consumes iterable through instance adder", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let values = []; let proto = Object.getPrototypeOf(new Set()); let original = proto.add; proto.add = function(value) { values.push(value); return this; }; let set = new Set([1, 2]); proto.add = original; [values.join(","), set.size].join(";")|,
      "1,2;0"
    )
  end

  test "constructor closes iterator when adder throws", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let closed = false; let proto = Object.getPrototypeOf(new Set()); let original = proto.add; proto.add = function() { throw new Error("boom"); }; let iterable = { [Symbol.iterator]() { return { next() { return {value: 1, done: false}; }, return() { closed = true; return {}; } }; } }; try { new Set(iterable); } catch (_) {} proto.add = original; closed|
           ) == true
  end

  test "constructor closes iterator only once for recursive abrupts", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let closed = 0; let proto = Object.getPrototypeOf(new Set()); let original = proto.add; let count = 0; proto.add = function() { if (++count === 2) throw new Error("boom"); return this; }; let iterable = { [Symbol.iterator]() { let i = 0; return { next() { return {value: ++i, done: false}; }, return() { closed++; return {}; } }; } }; try { new Set(iterable); } catch (_) {} proto.add = original; closed|
           ) == 1
  end

  test "constructor closes iterator when done or value access throws", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let closed = false; let iterable = { [Symbol.iterator]() { return { next() { return { get done() { throw new Error("boom"); } }; }, return() { closed = true; return {}; } }; } }; try { new Set(iterable); } catch (_) {} closed|
           ) == true

    assert run_beam_isolated!(
             ~S|let closedValue = false; let iterableValue = { [Symbol.iterator]() { return { next() { return { done: false, get value() { throw new Error("boom"); } }; }, return() { closedValue = true; return {}; } }; } }; try { new Set(iterableValue); } catch (_) {} closedValue|
           ) == true
  end

  test "WeakSet constructor closes iterator when done or value access throws", %{rt: rt} do
    assert beam!(
             rt,
             ~S|let weakClosedDone = false; let weakIterableDone = { [Symbol.iterator]() { return { next() { return { get done() { throw new Error("boom"); } }; }, return() { weakClosedDone = true; return {}; } }; } }; try { new WeakSet(weakIterableDone); } catch (_) {} weakClosedDone|
           ) == true

    assert run_beam_isolated!(
             ~S|let weakClosedValue = false; let weakIterableValue = { [Symbol.iterator]() { return { next() { return { done: false, get value() { throw new Error("boom"); } }; }, return() { weakClosedValue = true; return {}; } }; } }; try { new WeakSet(weakIterableValue); } catch (_) {} weakClosedValue|
           ) == true
  end

  defp run_beam_isolated!(code) do
    Task.async(fn ->
      {:ok, rt} = QuickBEAM.start()
      beam!(rt, code)
    end)
    |> Task.await()
  end

  test "set composition creates results without calling add", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let s1 = new Set([1, 2]); let s2 = new Set([2, 3]); let proto = Object.getPrototypeOf(s1); let original = proto.add; let count = 0; proto.add = function(v) { count++; return original.call(this, v); }; let result = s1.union(s2); proto.add = original; [[...result].join(","), count].join(";")|,
      "1,2,3;0"
    )
  end

  test "symmetricDifference preserves receiver order for toggled set-like duplicates", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let base = new Set(["a", "b", "c", "d", "e"]); let other = { size: 4, get has() { base.add("q"); return function() { throw new Error("unused"); }; }, keys() { let values = ["x", "b", "c", "c"]; let index = 0; return { next() { if (index === 0) { base.delete("b"); base.delete("c"); base.add("b"); base.add("d"); } return { done: index >= values.length, value: values[index++] }; } }; } }; let combined = base.symmetricDifference(other); [[...combined].join(","), [...base].join(",")].join(";")|,
      "a,c,d,e,q,x;a,d,e,q,b"
    )

    assert_modes(
      rt,
      ~S|let other = { size: 2, has() { return false; }, keys() { let values = [2, 2]; let i = 0; return { next() { return { done: i >= values.length, value: values[i++] }; } }; } }; [...new Set([1, 2, 3]).symmetricDifference(other)].join(",")|,
      "1,3,2"
    )
  end

  test "set composition uses observed keys method", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let other = new Set([2]); other.keys = function() { return [3].values(); }; [...new Set([1]).union(other)].join(",")|,
      "1,3"
    )
  end

  test "set composition calls has with receiver and propagates errors", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let other = { marker: 2, size: 3, has(v) { return this.marker === v; }, keys() { return [].values(); } }; [...new Set([1, 2]).difference(other)].join(",")|,
      "1"
    )

    assert_beam_error(
      rt,
      ~S|let other = { size: 2, has() { throw new TypeError("boom"); }, keys() { return [].values(); } }; new Set([1]).difference(other)|,
      "TypeError"
    )
  end

  test "set composition accepts array-backed set-like keys", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      let setLike = { size: 2, has(v) { return v === 5 || v === 6; }, keys() { return [5, 6].values(); } };
      [...new Set([1]).union(setLike)].join(",")
      """,
      "1,5,6"
    )
  end

  test "clear tombstones entries for live iterators", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let set = new Set([1, 2]); let iter = set.values(); set.clear(); set.add(3); [iter.next().value, iter.next().done].join(",")|,
      "3,true"
    )
  end
end
