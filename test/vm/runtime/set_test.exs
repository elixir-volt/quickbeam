defmodule QuickBEAM.VM.Runtime.SetTest do
  use QuickBEAM.VMCase, async: true

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

  test "clear tombstones entries for live iterators", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let set = new Set([1, 2]); let iter = set.values(); set.clear(); set.add(3); [iter.next().value, iter.next().done].join(",")|,
      "3,true"
    )
  end
end
