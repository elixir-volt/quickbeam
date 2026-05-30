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

  test "split handles constructor RegExp empty and class escape separators", %{rt: rt} do
    assert_modes(rt, ~S<"hello".split(new RegExp()).join("|")>, "h|e|l|l|o")
    assert_modes(rt, ~S<"hello".split(new RegExp(), 1).join("|")>, "h")

    assert_modes(
      rt,
      ~S"""
      "💩".split("").map(s => s.charCodeAt(0)).join("|")
      """,
      "55357|56489"
    )

    assert_modes(rt, ~S<"x".split(/\w/).join("|")>, "|")
    assert_modes(rt, ~S<"x".split(/\D/).join("|")>, "|")
    assert_modes(rt, ~S<"hello".split(/l/).join("|")>, "he||o")
    assert_modes(rt, ~S<"one two three".split(/ /, 2).join("|")>, "one|two")
    assert_modes(rt, ~S<"x".split(/.?/).join("|")>, "|")
  end

  test "split stringifies plain object separators before applying limit", %{rt: rt} do
    assert_modes(
      rt,
      ~S/let separator = {}; separator[Symbol.split] = null; separator.toString = () => "2"; "a2b2c".split(separator).join("|")/,
      "a|b|c"
    )

    assert_modes(
      rt,
      ~S/let separator = {toString() { throw "ok"; }}; try { "foo".split(separator, 0); "no" } catch (e) { e }/,
      "ok"
    )
  end

  test "matchAll requires observable RegExp flags to be object-coercible", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let r = /a/g; Object.defineProperty(r, "flags", {value: undefined}); try { "".matchAll(r); "no" } catch (e) { e.name }>,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S<Object.defineProperty(RegExp.prototype, "flags", {get() { return undefined; }}); try { "".matchAll(/a/g); "no" } catch (e) { e.name }>,
      "TypeError"
    )
  end

  test "matchAll nullish pattern invokes observable RegExp prototype matcher", %{rt: rt} do
    assert_modes(
      rt,
      ~S<let arg; let calls = 0; let receiver = {[Symbol.toPrimitive]() { calls++; return "abc"; }}; RegExp.prototype[Symbol.matchAll] = function(string) { arg = string; }; String.prototype.matchAll.call(receiver, null); calls + "|" + arg>,
      "1|abc"
    )
  end

  test "well-formed string methods coerce primitive receivers", %{rt: rt} do
    assert_modes(rt, ~S<String.prototype.isWellFormed.call(1)>, true)
    assert_modes(rt, ~S<String.prototype.toWellFormed.call(1n)>, "1")

    assert_modes(
      rt,
      ~S<try { String.prototype.isWellFormed.call(Symbol()) } catch (e) { e.name }>,
      "TypeError"
    )
  end

  test "fromCodePoint preserves surrogate code points", %{rt: rt} do
    assert beam!(rt, "String.fromCodePoint(0xD800) === ''") == false
  end
end
