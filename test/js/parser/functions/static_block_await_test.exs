defmodule QuickBEAM.JS.Parser.Functions.StaticBlockAwaitTest do
  use ExUnit.Case, async: true

  alias QuickBEAM.JS.Parser
  alias QuickBEAM.JS.Parser.AST

  test "allows await references in non-async function expressions inside static blocks" do
    for source <- [
          "class C { static { (function (x = await) { fromBody = await; })(); } }",
          "class C { static { (function * (x = await) { fromBody = await; })().next(); } }"
        ] do
      assert {:ok, %AST.Program{}} = Parser.parse(source)
    end
  end
end
