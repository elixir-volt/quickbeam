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
end
