defmodule QuickBEAM.VM.Runtime.RegExpTest do
  use QuickBEAM.VMCase, async: true

  test "class escapes use unanchored membership semantics", %{rt: rt} do
    assert_modes(
      rt,
      """
      [
        /\\D/.test('a1'),
        /\\D/.test('12'),
        /\\W/.test('a!'),
        /\\W/.test('a_1'),
        /\\S/.test(' a'),
        /\\S/.test(' \\t\\n')
      ].join(',')
      """,
      "true,false,true,false,true,false"
    )
  end

  test "unicode indices fallback does not count lookbehind as a capture", %{rt: rt} do
    assert beam!(rt, "/(?<=a)b/du.exec('ab').indices.length") == 1
  end

  test "global exec advances and resets lastIndex", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /a/g; let first = r.exec("ba"); let afterFirst = r.lastIndex; let second = r.exec("ba"); [first.index, afterFirst, second, r.lastIndex].join(",")|,
      "1,2,,0"
    )
  end

  test "global exec treats infinite lastIndex as out of range", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /a/g; r.lastIndex = Infinity; let result = r.exec("a"); [result, r.lastIndex].join(",")|,
      ",0"
    )
  end

  test "special global exec paths use UTF-16 lastIndex", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /\Bdef/g; r.lastIndex = 3; let result = r.exec("😀abcdef"); [result.index, r.lastIndex].join(",")|,
      "5,8"
    )

    assert_modes(
      rt,
      ~S|let r = /(?<=^(\w+))def/g; r.lastIndex = 2; let result = r.exec("abcdef😀"); [result.index, r.lastIndex, result[1]].join(",")|,
      "3,6,abc"
    )
  end

  test "special global exec paths reset large lastIndex", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /\Bdef/g; r.lastIndex = 99; let result = r.exec("abcdef"); [result, r.lastIndex].join(",")|,
      ",0"
    )

    assert_modes(
      rt,
      ~S|let r = /(?<=^(\w+))def/g; r.lastIndex = 99; let result = r.exec("abcdef"); [result, r.lastIndex].join(",")|,
      ",0"
    )
  end

  test "stateful exec uses UTF-16 lastIndex", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /a/y; r.lastIndex = 2; let result = r.exec("😀a"); [result.index, r.lastIndex].join(",")|,
      "2,3"
    )

    assert_modes(
      rt,
      ~S|let r = /a/g; r.lastIndex = 2; let result = r.exec("😀a"); [result.index, r.lastIndex].join(",")|,
      "2,3"
    )
  end

  test "stateful exec throws when lastIndex cannot be written", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /b/g; Object.defineProperty(r, "lastIndex", { writable: false }); try { r.exec("a"); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "sticky exec requires a match at lastIndex", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = /a/y; r.lastIndex = 1; let first = r.exec("ba"); let afterFirst = r.lastIndex; r.lastIndex = 0; let second = r.exec("ba"); [first.index, afterFirst, second, r.lastIndex].join(",")|,
      "1,2,,0"
    )
  end
end
