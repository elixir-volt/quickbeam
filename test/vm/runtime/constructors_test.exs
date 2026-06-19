defmodule QuickBEAM.VM.Runtime.ConstructorsTest do
  use QuickBEAM.VM.TestCase, async: true

  test "core constructor prototypes are visible through generic builtin lookup", %{rt: rt} do
    assert_modes(
      rt,
      ~S<[typeof String.prototype, typeof Number.prototype, typeof Symbol.prototype, typeof BigInt.prototype].join("|")>,
      "object|object|object|object"
    )
  end

  test "builtin constructor statics are restored through generic metadata lookup", %{rt: rt} do
    assert_modes(
      rt,
      ~S<[typeof Symbol.iterator, Symbol.keyFor(Symbol.for("x"))].join("|")>,
      "symbol|x"
    )

    assert_modes(
      rt,
      ~S<[Uint8Array.BYTES_PER_ELEMENT, typeof Uint8Array.from, typeof Uint8Array.prototype].join("|")>,
      "1|function|object"
    )

    assert_modes(
      rt,
      ~S<[typeof Array.from, Number.MAX_SAFE_INTEGER, typeof String.fromCodePoint].join("|")>,
      "function|9007199254740991|function"
    )
  end
end
