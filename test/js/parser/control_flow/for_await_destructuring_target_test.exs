defmodule QuickBEAM.JS.Parser.ControlFlow.ForAwaitDestructuringTargetTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "rejects invalid destructuring assignment targets in for-await-of heads" do
    for source <- [
          "async function fn() { for await ([[(x, y)]] of [[[]]]) {} }",
          "async function fn() { for await ([{ get x() {} }] of [[{}]]) {} }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "invalid destructuring target"))
    end
  end

  test "allows arbitrary initializer expressions in for-await-of destructuring heads" do
    assert {:ok, %AST.Program{}} =
             Parser.parse(
               "async function fn() { for await ([x = (0, function() {}), y = (function() {})] of [[]]) {} }"
             )
  end

  test "rejects strict restricted names in for-await-of destructuring assignment heads" do
    for source <- [
          "'use strict'; async function fn() { for await ([arguments] of [[]]) {} }",
          "'use strict'; async function fn() { for await ([x = yield] of [[]]) {} }",
          "'use strict'; async function fn() { for await ([x[yield]] of [[]]) {} }",
          "'use strict'; async function fn() { for await ([...x[yield]] of [[]]) {} }"
        ] do
      assert {:error, %AST.Program{}, errors} = Parser.parse(source)
      assert Enum.any?(errors, &(&1.message == "restricted assignment target in strict mode"))
    end
  end
end
