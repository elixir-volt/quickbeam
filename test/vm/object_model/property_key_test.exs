defmodule QuickBEAM.VM.ObjectModel.PropertyKeyTest do
  use QuickBEAM.VMCase, async: true

  test "computed property reads convert key once before property access", %{rt: rt} do
    assert_modes(
      rt,
      """
      let log = [];
      let key = { toString() { log.push('key'); return 'a'; } };
      let object = { get a() { log.push('get'); return 1; } };
      object[key];
      log.join(',');
      """,
      "key,get"
    )
  end

  test "computed assignment converts key before right-hand side", %{rt: rt} do
    assert_modes(
      rt,
      """
      let log = [];
      let key = { toString() { log.push('key'); return 'a'; } };
      let object = {};
      object[key] = (log.push('value'), 1);
      log.join(',') + '|' + object.a;
      """,
      "key,value|1"
    )
  end
end
