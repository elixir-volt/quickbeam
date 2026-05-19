defmodule QuickBEAM.VM.Runtime.StringTest do
  use QuickBEAM.VM.TestCase, async: true

  test "custom global RegExp exec replaces all matches", %{rt: rt} do
    assert beam!(rt, """
           let regexp = /a/g;
           regexp.exec = function (string) {
             let index = string.indexOf('a', this.lastIndex);
             if (index < 0) return null;
             this.lastIndex = index + 1;
             return Object.assign(['a'], { index, input: string });
           };
           'aba'.replace(regexp, 'x');
           """) == "xbx"
  end

  test "bytecode RegExp replace honors custom exec", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let regexp = /a/g; regexp.exec = function (string) { let index = string.indexOf('a', this.lastIndex); if (index < 0) return null; this.lastIndex = index + 1; return Object.assign(['a'], { index, input: string }); }; 'aba'.replace(regexp, 'x');|,
      "xbx"
    )
  end

  test "named replacements use actual named capture numbering", %{rt: rt} do
    assert beam!(rt, "'ab'.replace(/(a)(?<b>b)/, '$<b>')") == "b"
  end

  test "RegExp constructed from named group source passes groups to functional replacer", %{
    rt: rt
  } do
    assert_modes(
      rt,
      ~S|let re = new RegExp("(?<fst>.)(?<snd>.)", "g"); "abcd".replace(re, (match, fst, snd, offset, str, groups) => groups.snd + groups.fst)|,
      "badc"
    )

    assert_modes(
      rt,
      """
      let re = new RegExp("(?<fst>.)|(?<snd>.)", "");
      "abcd".replace(re, (match, fst, snd, offset, str, groups) => String(groups.snd))
      """,
      "undefinedbcd"
    )
  end

  test "fromCodePoint preserves surrogate code points", %{rt: rt} do
    assert beam!(rt, "String.fromCodePoint(0xD800) === ''") == false
  end
end
