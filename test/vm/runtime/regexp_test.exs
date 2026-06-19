defmodule QuickBEAM.VM.Runtime.RegExpTest do
  use QuickBEAM.VM.TestCase, async: true

  test "RegExp internal flags stay separate from own flags property", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let r = /a/g; Object.defineProperty(r, "flags", {value: "", configurable: true}); let own = r.flags; let globalBefore = r.global; delete r.flags; [own, globalBefore, r.global].join("|")>,
      "|true|true"
    )
  end

  test "RegExp generic toString and custom exec validation", %{rt: rt} do
    assert beam!(rt, ~S|RegExp.prototype.toString.call({source: "a", flags: "g"})|) == "/a/g"

    assert_modes(
      rt,
      ~S|let r = {exec() { return undefined; }}; try { RegExp.prototype.test.call(r, "x"); "no" } catch (e) { e.name }|,
      "TypeError"
    )
  end

  test "String matchAll validates global flag before custom matcher", %{rt: rt} do
    assert_modes(
      rt,
      ~S|let r = {[Symbol.match]: true, flags: "", [Symbol.matchAll]() { throw "wrong"; }}; try { "abc".matchAll(r); "no" } catch (e) { e.name }|,
      "TypeError"
    )
  end

  test "String matchAll creates global regexps for string patterns", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let a = [..."aba".matchAll("a")]; [a.length, a[0].index, a[1].index].join("|")>,
      "2|0|2"
    )
  end

  test "closed locals keep existing captured cell identity", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let f; { let y = 1; f = function() { return ++y; }; y = 2; } [f(), f()].join("|")>,
      "3|4"
    )
  end

  test "RegExp string replacement handles unicode and named capture templates", %{rt: rt} do
    assert_modes(rt, ~S</b/u[Symbol.replace]("abc", "$&$<food")>, "ab$<foodc")
    assert_modes(rt, ~S|/(?<foo>.)(?<bar>.)/gu[Symbol.replace]("abc", "$2$<foo>$1")|, "baac")
    assert_modes(rt, ~S|/(?<𝒜>b)/u[Symbol.replace]("abc", "d$<𝒜>$`")|, "adbac")
  end

  test "RegExp replacement advances empty global matches by observable unicode flag", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let r = /^|\udf06/g; Object.defineProperty(r, "unicode", {writable: true}); r.unicode = false; let s = r[Symbol.replace]("\ud834\udf06", "XXX"); [s.length, s.charCodeAt(3), s.slice(4)].join("|")>,
      "7|55348|XXX"
    )

    assert_modes(
      rt,
      ~S<let r = /^|\udf06/g; Object.defineProperty(r, "unicode", {writable: true}); r.unicode = true; let s = r[Symbol.replace]("\ud834\udf06", "XXX"); [s.length, s.charCodeAt(3), s.charCodeAt(4)].join("|")>,
      "5|55348|57094"
    )
  end

  test "RegExp split uses species clone and throwing lastIndex writes", %{rt: rt} do
    assert beam!(
             rt,
             ~S<let re = /x/iy; re.constructor = function() {}; re.constructor[Symbol.species] = function() { return /[db]/y; }; RegExp.prototype[Symbol.split].call(re, "abcde").join("|")>
           ) == "a|c|e"

    assert_modes(
      rt,
      ~S<let r = /a/; Object.defineProperty(r, "lastIndex", {writable: false}); try { RegExp.prototype[Symbol.split].call(r, "a"); "no" } catch (e) { e.name }>,
      "no"
    )
  end

  test "RegExp indexes use UTF-16 code units", %{rt: rt} do
    assert_modes(rt, ~S<new RegExp("b").exec("💩b").index>, 2)
    assert_modes(rt, ~S</b/.exec("💩b").index>, 2)
    assert_modes(rt, ~S<[...new RegExp("b")[Symbol.matchAll]("💩b")][0].index>, 2)
  end

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
