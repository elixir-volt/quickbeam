defmodule QuickBEAM.VM.Compiler.DestructuringTest do
  use QuickBEAM.VMCase, async: true

  test "object binding requires object coercible source", %{rt: rt} do
    assert_modes(
      rt,
      ~S|try { var {a} = null; "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )

    assert_modes(
      rt,
      ~S|try { ({a} = undefined); "ok"; } catch (e) { e.name; }|,
      "TypeError"
    )
  end

  test "object binding permits primitive coercible source", %{rt: rt} do
    assert_modes(rt, ~S|var {length} = "abc"; length|, 3)
  end

  test "object rest binding copies non-excluded properties", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var obj = {a: 1, b: 2}; var {a, ...rest} = obj; JSON.stringify(rest)|,
      ~S|{"b":2}|
    )
  end

  test "object rest assignment copies string indexes", %{rt: rt} do
    assert_modes(
      rt,
      ~S|var rest; for ({...rest} of ["foo"]) {} [rest["0"], rest["1"], rest["2"]].join("")|,
      "foo"
    )
  end

  test "object rest assignment target obeys const semantics", %{rt: rt} do
    code = ~S|const rest = null; try { for ({...rest} of [{}]) {} "no"; } catch (e) { e.name; }|

    assert_modes(rt, code, "TypeError")
  end

  test "object rest binding skips getOwnPropertyDescriptor for computed and literal excluded keys",
       %{rt: rt} do
    code = """
    var excludedSymbol = Symbol("excluded_symbol");
    var includedSymbol = Symbol("included_symbol");
    var getOwnKeys = [];
    var proxy = new Proxy({}, {
      ownKeys() { return [excludedSymbol, "excludedString", "0", includedSymbol, "includedString", "1"]; },
      getOwnPropertyDescriptor(_target, key) { getOwnKeys.push(key); }
    });
    var {[excludedSymbol]: _, excludedString, 0: excludedIndex, ...rest} = proxy;
    getOwnKeys.map(key => key === includedSymbol ? "includedSymbol" : String(key)).join(",");
    """

    assert_modes(rt, code, "includedSymbol,includedString,1")
  end

  test "object rest binding skips getOwnPropertyDescriptor for literal excluded keys", %{rt: rt} do
    code = """
    var calls = [];
    var proxy = new Proxy({}, {
      ownKeys() { return ["x", "a"]; },
      getOwnPropertyDescriptor(_target, key) { calls.push(key); }
    });
    var {x: _, ...rest} = proxy;
    calls.join(",");
    """

    assert_modes(rt, code, "a")
  end
end
