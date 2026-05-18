defmodule QuickBEAM.VM.Runtime.ArrayTest do
  use QuickBEAM.VMCase, async: true

  test "array callbacks skip sparse holes without missing high indexes", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      var calls = [];
      var array = [1];
      array[100001] = 2;
      var every = array.every(function(value, index) { calls.push(index + ':' + value); return true; });
      var mapped = array.map(function(value) { return value + 1; });
      var filtered = array.filter(function(value) { return value > 1; });
      var some = array.some(function(value, index) { calls.push('s' + index + ':' + value); return false; });
      [every, some, calls.join(','), mapped[100001], filtered[0]].join('|')
      """,
      "true|false|0:1,100001:2,s0:1,s100001:2|3|2"
    )
  end

  test "array indexOf searches sparse high indexes", %{rt: rt} do
    assert_modes(
      rt,
      ~S"""
      var marker = {};
      var array = [];
      array[100001] = marker;
      array.indexOf(marker)
      """,
      100_001
    )
  end
end
