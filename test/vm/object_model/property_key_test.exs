defmodule QuickBEAM.VM.ObjectModel.PropertyKeyTest do
  use QuickBEAM.VM.TestCase, async: true

  test "Reflect methods coerce property keys", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let log = []; let key = {toString(){ log.push("toString"); return "x"; }}; Reflect.get({x: 1}, key) + "|" + log.join(",")>,
      "1|toString"
    )

    assert_modes(
      rt,
      ~S<let log = []; let key = {toString(){ log.push("toString"); return "x"; }}; let obj = {}; Reflect.set(obj, key, 2); obj.x + "|" + log.join(",")>,
      "2|toString"
    )
  end

  alias QuickBEAM.VM.ObjectModel.PropertyKey

  test "array index classification follows canonical array-index strings" do
    assert PropertyKey.array_index("0") == {:ok, 0}
    assert PropertyKey.array_index("01") == :error
    assert PropertyKey.array_index("4294967294") == {:ok, 4_294_967_294}
    assert PropertyKey.array_index("4294967295") == :error
    assert PropertyKey.array_index(-0.0) == {:ok, 0}
  end

  test "integer index classification is not capped to array-index range" do
    assert PropertyKey.integer_index("4294967294") == {:ok, 4_294_967_294}
    assert PropertyKey.integer_index("4294967295") == {:ok, 4_294_967_295}
    assert PropertyKey.integer_index("01") == :error
  end

  test "own key sorting preserves string and symbol order after indexes" do
    sym = {:symbol, "s"}

    assert PropertyKey.sort_own_keys(["b", "2", sym, "1", "01", "a"]) == [
             "1",
             "2",
             "b",
             "01",
             "a",
             sym
           ]
  end

  test "computed property reads convert key once before property access", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let log = []; let key = { toString() { log.push('key'); return 'a'; } }; let object = { get a() { log.push('get'); return 1; } }; object[key]; log.join(',');>,
      "key,get"
    )
  end

  test "computed assignment converts key before right-hand side", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let log = []; let key = { toString() { log.push('key'); return 'a'; } }; let object = {}; object[key] = (log.push('value'), 1); log.join(',') + '|' + object.a;>,
      "key,value|1"
    )
  end
end
